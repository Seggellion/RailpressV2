require "test_helper"
require "vips"

class NativeImageTest < ActiveSupport::TestCase
  test "selected native image stack creates and resizes synthetic image" do
    image = Vips::Image.black(8, 8).new_from_image([ 20, 30, 40 ])
    bytes = image.write_to_buffer(".png")
    resized = Vips::Image.thumbnail_buffer(bytes, 4)
    assert_equal [ 4, 4 ], [ resized.width, resized.height ]
    assert_operator resized.write_to_buffer(".png").bytesize, :>, 0
  end
end
