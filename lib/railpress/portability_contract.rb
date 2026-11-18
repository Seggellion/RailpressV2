# Signed bundle reader capability; content portability never carries executable code.
module Railpress
  module PortabilityContract
    VERSION = 3
    MAX_ARCHIVE = 128 * 1024 * 1024
    MAX_MANIFEST = 16 * 1024 * 1024
    MAX_CONTENT = 500
    MAX_REVISIONS = 2000
    MAX_MEDIA = 64
  end
end
