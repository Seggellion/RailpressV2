require "vips"
require "stringio"
require_relative "editorial_test_support"
module MediaTestSupport
  extend ActiveSupport::Concern
  include EditorialTestSupport
  def with_method(target, name, replacement)
    original = target.method(name)
    target.define_singleton_method(name, &replacement)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
  def image_bytes(format = ".png", width: 80, height: 40)
    Vips::Image.black(width, height).new_from_image([ 36, 91, 120 ]).write_to_buffer(format)
  end
  def upload_media(actor: @author, bytes: image_bytes, filename: "studio.png", type: "image/png", **metadata)
    MediaLibrary::Upload.call(actor: actor, io: StringIO.new(bytes), filename: filename, content_type: type,
      attributes: { "title" => "Studio image", "alt_text" => "A synthetic blue studio" }.merge(metadata.stringify_keys))
  end
  def media_change(content, **attributes)
    change(content, attributes: attributes)
  end
end
