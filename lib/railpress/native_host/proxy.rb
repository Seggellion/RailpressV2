# frozen_string_literal: true

module Railpress
  module NativeHost
    class Proxy
      def initialize(config, processes)
        @config, @processes = config, processes
      end
      def config_bytes(id:, slot:, generation:, maintenance: false)
        Releases.identity!(id)
        raise Error, "service_slot" unless [ 0, 1 ].include?(slot)
        Releases.integer!(generation, 0, 2**53 - 1)
        # Paths become native configuration syntax, so reject every metacharacter.
        [ @config.root, @config.data["nginx_binary"] ].each do |value|
          raise Error, "proxy_path" unless value.match?(%r{\A/[a-zA-Z0-9_./-]+\z})
        end
        root = @config.root
        port = @config.data["edge_port"]
        backend = @config.data["puma_ports"][slot]
        location = maintenance ? 'add_header Cache-Control no-store always; add_header X-Robots-Tag "noindex, nofollow" always; return 503 "Maintenance: explicit recovery operation in progress.\\n";' :
          "proxy_pass http://127.0.0.1:#{backend};"
        <<~NGINX
          worker_processes 1;
          worker_shutdown_timeout 10s;
          pid #{root}/proxy/nginx.pid;
          error_log #{root}/logs/nginx-error.log warn;
          events { worker_connections 256; }
          http {
            types { text/css css; application/javascript js; image/png png; image/svg+xml svg; image/x-icon ico; text/plain txt; application/json json; }
            log_format bounded '$request_method $uri $status $upstream_addr $request_time';
            access_log #{root}/logs/nginx-access.log bounded;
            client_body_temp_path #{root}/proxy/body;
            proxy_temp_path #{root}/proxy/temp;
            fastcgi_temp_path #{root}/proxy/fastcgi;
            uwsgi_temp_path #{root}/proxy/uwsgi;
            scgi_temp_path #{root}/proxy/scgi;
            keepalive_timeout 1s;
            server {
              listen 127.0.0.1:#{port} ssl;
              server_name localhost;
              if ($host != localhost) { return 421; }
              ssl_certificate #{root}/proxy/cert.pem;
              ssl_certificate_key #{root}/proxy/key.pem;
              ssl_protocols TLSv1.2 TLSv1.3;
              client_max_body_size 16m;
              location = /__railpress_deployment {
                allow 127.0.0.1; deny all;
                default_type application/json;
                add_header Cache-Control no-store always;
                return 200 '{"release_id":"#{id}","generation":#{generation},"maintenance":#{maintenance}}';
              }
              location ~ (^|/)\\. { return 404; }
              location /assets/ {
                alias #{root}/shared/assets/;
                add_header Cache-Control "public, max-age=31536000, immutable";
              }
              location / {
                proxy_set_header Host localhost:#{port};
                proxy_set_header X-Forwarded-Proto https;
                proxy_set_header X-Forwarded-Host localhost:#{port};
                proxy_set_header X-Forwarded-Port #{port};
                proxy_set_header X-Forwarded-For $remote_addr;
                proxy_set_header Forwarded "";
                proxy_connect_timeout 2s;
                proxy_read_timeout 5s;
                proxy_send_timeout 5s;
                #{location}
              }
            }
          }
        NGINX
      end
      def write_initial!(**options)
        bytes = config_bytes(**options)
        validate!(bytes)
        F.atomic(@config.path("proxy", "nginx.conf"), bytes)
      end
      def switch!(record, **options)
        bytes = config_bytes(**options)
        validate!(bytes)
        children = child_ids(record)
        F.atomic(@config.path("proxy", "nginx.conf"), bytes)
        @processes.signal(record, "HUP")
        deadline = SecurityClock.elapsed + 15
        probe = Probe.new(@config)
        loop do
          result = probe.request("/__railpress_deployment")
          actual = Releases.parse(result["body"], limit: 8192)
          break if result["status"] == 200 && actual == options.slice(:id, :generation, :maintenance).transform_keys { |key| key == :id ? "release_id" : key.to_s }.merge("maintenance" => options.fetch(:maintenance, false))
          raise Error, "proxy_switch_unconfirmed" if SecurityClock.elapsed > deadline
          sleep 0.02
        end
        while (child_ids(record) & children).any?
          raise Error, "proxy_drain_deadline" if SecurityClock.elapsed > deadline
          sleep 0.02
        end
        true
      end
      def validate!(bytes)
        file = @config.path("proxy", "check-#{SecureRandom.uuid}.conf")
        F.atomic(file, bytes)
        Commands.run([ @config.data["nginx_binary"], "-t", "-p", @config.path("proxy") + "/", "-c", file ],
          env: { "PATH" => "/usr/bin:/bin" }, log: @config.path("logs", "proxy-check-#{SecureRandom.uuid}.log"))
      ensure
        File.unlink(file) if file && File.file?(file) && !File.symlink?(file)
      end
      def child_ids(record)
        raise Error, "proxy_identity_changed" unless @processes.verified(record)
        File.read("/proc/#{record.fetch('pid')}/task/#{record.fetch('pid')}/children").split.map { |value| Integer(value) }
      rescue SystemCallError
        raise Error, "proxy_process_unavailable"
      end
    end
  end
end
