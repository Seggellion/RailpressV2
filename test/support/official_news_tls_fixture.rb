require "openssl"
require "socket"
require "timeout"
directory, mode=ARGV
context=OpenSSL::SSL::SSLContext.new
context.cert=OpenSSL::X509::Certificate.new(File.read(File.join(directory, "certificate.pem")))
context.key=OpenSSL::PKey.read(File.read(File.join(directory, "key.pem")))
tcp=TCPServer.new("127.0.0.1", 0)
File.write(File.join(directory, "port"), tcp.addr[1].to_s)
server=OpenSSL::SSL::SSLServer.new(tcp, context)
begin
  Timeout.timeout(9) do
    socket=server.accept
    request=+""
    request<<socket.readpartial(1024) until request.include?("\r\n\r\n")
    File.write(File.join(directory, "request"), request)
    body=File.read(File.join(directory, "payload.json"))
    common="Content-Type: application/json\r\nConnection: close\r\n"
    case mode
    when "redirect"
      socket.write("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    when "headers"
      socket.write("HTTP/1.1 200 OK\r\nX-Oversized: "+("x"*32768)+"\r\n\r\n")
    when "oversize"
      socket.write("HTTP/1.1 200 OK\r\n#{common}Content-Length: 262145\r\n\r\n")
    when "encoded"
      socket.write("HTTP/1.1 200 OK\r\n#{common}Content-Encoding: gzip\r\nContent-Length: 1\r\n\r\nx")
    when "html"
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
    when "slow"
      socket.write("HTTP/1.1 200 OK\r\n#{common}Content-Length: 100\r\n\r\n");sleep 6
    when "drip"
      socket.write("HTTP/1.1 200 OK\r\n#{common}Content-Length: 100\r\n\r\n")
      30.times { socket.write(" ");sleep 0.4 }
    when "not_modified"
      socket.write("HTTP/1.1 304 Not Modified\r\nETag: \"synthetic-safe-etag\"\r\nConnection: close\r\n\r\n")
    else
      socket.write("HTTP/1.1 200 OK\r\n#{common}Content-Length: #{body.bytesize}\r\nETag: \"synthetic-safe-etag\"\r\nLast-Modified: Fri, 13 Nov 2026 00:00:00 GMT\r\n\r\n#{body}")
    end
    socket.close
  end
rescue OpenSSL::SSL::SSLError, IOError, Errno::EPIPE, Errno::ECONNRESET, Timeout::Error
ensure
  tcp.close
end
