require "test_helper"
class UploadBodyLimitTest < ActiveSupport::TestCase
  test "declared large uploads are rejected before the application parses multipart" do
    app=Railpress::UploadBodyLimit.new(->(_env) { flunk "Oversize body reached application" })
    status, headers, _body=app.call("PATH_INFO"=>"/admin/media_assets", "REQUEST_METHOD"=>"POST", "CONTENT_LENGTH"=>(Railpress::UploadBodyLimit::MAX_REQUEST_BYTES+1).to_s, "rack.input"=>StringIO.new(""))
    assert_equal 413, status
    assert_equal "no-store", headers["cache-control"]
  end
  test "unknown length stream cannot exceed the request byte budget" do
    app=Railpress::UploadBodyLimit.new(->(env) { env.fetch("rack.input").read;[ 200, {}, [] ] })
    status, _headers, _body=app.call("PATH_INFO"=>"/admin/media_assets", "REQUEST_METHOD"=>"POST", "rack.input"=>StringIO.new("x"*(Railpress::UploadBodyLimit::MAX_REQUEST_BYTES+1)))
    assert_equal 413, status
  end
end
