require "openssl"
require "socket"
require "timeout"
# Separate native test process, not an app endpoint or diagnostic safety exemption.
directory, mode=ARGV
certificate=OpenSSL::X509::Certificate.new(File.read(File.join(directory, "certificate.pem")))
key=OpenSSL::PKey.read(File.read(File.join(directory, "key.pem")))
context=OpenSSL::SSL::SSLContext.new
context.cert=certificate;context.key=key
tcp=TCPServer.new("127.0.0.1", 0)
File.write(File.join(directory, "port.pending"), tcp.addr[1].to_s)
File.rename(File.join(directory, "port.pending"), File.join(directory, "port"))
server=OpenSSL::SSL::SSLServer.new(tcp, context)
begin
  Timeout.timeout(5) do
    socket=server.accept
    request=+""
    request<<socket.readpartial(1024) until request.include?("\r\n\r\n")
    File.write(File.join(directory, "request"), request)
    body="<html><p>native TLS</p></html>"
    case mode
    when "headers" then socket.write("HTTP/1.1 200 OK\r\nX-Unbounded: "+("x"*32_768)+"\r\n\r\n")
    when "oversize" then socket.write("HTTP/1.1 200 OK\r\nContent-Length: 9999\r\nConnection: close\r\n\r\n")
    when "encoded" then socket.write("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
    when "slow" then socket.write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n");sleep 3
    else socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
    end
    socket.close
  end
rescue OpenSSL::SSL::SSLError, IOError, Errno::EPIPE, Timeout::Error
  # Client refusal/deadline is an expected fixture outcome.
ensure
  tcp.close
end
