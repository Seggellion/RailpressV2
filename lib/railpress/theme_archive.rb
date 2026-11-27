# frozen_string_literal: true

require "fileutils"
require "timeout"
require "zlib"
require_relative "theme_package"

module Railpress
  module ThemeArchive
    MAX_BYTES = 4 * 1024 * 1024
    MAX_ENTRIES = 48
    MAX_RATIO = 100
    DEADLINE = 10
    END_RECORD = "PK\x05\x06".b.freeze
    INVALID = ThemePackage::Invalid
    Entry = Data.define(:name, :directory, :version, :flags, :method, :dos_time, :dos_date, :crc, :compressed, :expanded, :offset)

    class Reader
      def initialize(file)
        @file = file
        @archive_size = file.stat.size
        @deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DEADLINE
        raise INVALID, "zip_size" unless (22..MAX_BYTES).cover?(@archive_size)
      end

      def extract!(root)
        remaining = @deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise INVALID, "zip_deadline" unless remaining.positive?
        Timeout.timeout(remaining) { extract_records!(root) }
      rescue Timeout::Error
        raise INVALID, "zip_deadline", cause: nil
      rescue Zlib::Error
        raise INVALID, "zip_deflate", cause: nil
      end

      private

      def extract_records!(root)
        entries, central_offset = inventory
        names = entries.map(&:name)
        raise INVALID, "zip_duplicate_name" unless names.map(&:downcase).uniq.length == names.length
        files = entries.reject(&:directory)
        entries.select(&:directory).each do |directory|
          raise INVALID, "zip_unnecessary_directory" unless files.any? { |file| file.name.start_with?("#{directory.name}/") }
        end
        compressed = entries.sum(&:compressed)
        expanded = entries.sum(&:expanded)
        raise INVALID, "zip_expanded_size" if @archive_size - compressed + expanded > MAX_BYTES
        raise INVALID, "zip_ratio" if expanded > compressed * MAX_RATIO
        offset = 0
        entries.sort_by(&:offset).each do |entry|
          check_time!
          raise INVALID, "zip_local_range" unless entry.offset == offset && entry.offset < central_offset
          offset = extract_entry(entry, root, central_offset)
        end
        raise INVALID, "zip_local_range" unless offset == central_offset
        check_time!
      end

      def inventory
        start = [ @archive_size - 65_557, 0 ].max
        @file.seek(start)
        tail = read_exact(@archive_size - start)
        position = end_position(tail)
        raise INVALID, "zip_end_record" unless position
        _, disk, central_disk, disk_entries, count, size, offset, comment = tail.byteslice(position, 22).unpack("VvvvvVVv")
        raise INVALID, "zip_directory" unless disk.zero? && central_disk.zero? && disk_entries == count &&
          (1..MAX_ENTRIES).cover?(count) && offset.positive? && offset + size == start + position &&
          position + 22 + comment == tail.bytesize
        @file.seek(offset)
        entries = Array.new(count) { central_entry(offset + size) }
        raise INVALID, "zip_directory" unless @file.pos == offset + size
        [ entries, offset ]
      end

      def end_position(tail)
        position = tail.rindex(END_RECORD, tail.bytesize - 22) if tail.bytesize >= 22
        while position
          check_time!
          comment = tail.byteslice(position + 20, 2).unpack1("v")
          return position if position + 22 + comment == tail.bytesize
          return if position.zero?
          position = tail.rindex(END_RECORD, position - 1)
        end
      end

      def central_entry(limit)
        check_time!
        raise INVALID, "zip_directory" if @file.pos + 46 > limit
        signature, maker, version, flags, method, dos_time, dos_date, crc, compressed, expanded, name_size, extra_size, comment_size,
          disk, _internal, external, offset = read_exact(46).unpack("VvvvvvvVVVvvvvvVV")
        raise INVALID, "zip_central_header" unless signature == 0x02014b50 && disk.zero? && version.between?(10, 20) &&
          (flags & ~0x0808).zero? && [ 0, 8 ].include?(method) && (1..160).cover?(name_size) &&
          @file.pos + name_size + extra_size + comment_size <= limit
        raw_name = read_exact(name_size)
        directory = raw_name.end_with?("/")
        name = raw_name.delete_suffix("/")
        path!(name, directory)
        attributes!(maker, external, directory)
        check_extra!(read_exact(extra_size))
        @file.seek(comment_size, IO::SEEK_CUR)
        if directory
          raise INVALID, "zip_directory_payload" unless [ crc, expanded, compressed, method ].all?(&:zero?) && (flags & 8).zero?
        else
          raise INVALID, "zip_file_size" unless (1..file_limit(name)).cover?(expanded) && compressed.positive?
          raise INVALID, "zip_ratio" if expanded > compressed * MAX_RATIO
          raise INVALID, "zip_stored_size" if method.zero? && expanded != compressed
        end
        Entry.new(name:, directory:, version:, flags:, method:, dos_time:, dos_date:, crc:, compressed:, expanded:, offset:)
      end

      def path!(name, directory)
        unless name.ascii_only? && name.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*(?:\/[A-Za-z0-9][A-Za-z0-9_.-]*){0,2}\z/) &&
            name.split("/").none? { |part| part.end_with?(".") || part.match?(/\A(?:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|\z)/i) }
          raise INVALID, "zip_path"
        end
        allowed = if directory
          %w[templates templates/slots assets].include?(name)
        else
          %w[manifest.json signature.json LICENSE.txt].include?(name) ||
            name.match?(%r{\Atemplates/(?:slots/)?[a-z0-9_]+\.html\.erb\z}) ||
            name.match?(%r{\Aassets/[a-z0-9][a-z0-9._-]*\.(?:css|png|webp)\z})
        end
        raise INVALID, "zip_path" unless allowed
      end

      def attributes!(maker, attributes, directory)
        system = maker >> 8
        mode = attributes >> 16
        kind = mode & 0o170000
        dos_directory = (attributes & 0x10).positive?
        raise INVALID, "zip_file_type" unless [ 0, 3, 10, 19 ].include?(system) &&
          [ 0, directory ? 0o040000 : 0o100000 ].include?(kind) && !(dos_directory && !directory) &&
          (directory || (mode & 0o7111).zero?)
      end

      def file_limit(name)
        case name
        when "signature.json" then 2048
        when "manifest.json", "LICENSE.txt", /\.erb\z/ then 65_536
        when /\.css\z/ then 262_144
        else 1_048_576
        end
      end

      def check_extra!(extra)
        offset = 0
        seen = []
        while offset < extra.bytesize
          prefix = extra.byteslice(offset, 4)
          raise INVALID, "zip_extra" unless prefix.bytesize == 4
          tag, size = prefix.unpack("vv")
          offset += 4 + size
          unless [ 0x5455, 0x7875 ].include?(tag) && !seen.include?(tag) && size <= 32 && offset <= extra.bytesize
            raise INVALID, "zip_extra"
          end
          seen << tag
        end
      end

      def extract_entry(entry, root, limit)
        @file.seek(entry.offset)
        raise INVALID, "zip_local_range" if @file.pos + 30 > limit
        signature, version, flags, method, dos_time, dos_date, crc, compressed, expanded, name_size, extra_size =
          read_exact(30).unpack("VvvvvvVVVvv")
        descriptor = (flags & 8).positive?
        expected = [ entry.crc, entry.compressed, entry.expanded ]
        local = [ crc, compressed, expanded ]
        name = entry.directory ? "#{entry.name}/" : entry.name
        raise INVALID, "zip_local_header" unless signature == 0x04034b50 && version == entry.version &&
          flags == entry.flags && method == entry.method && dos_time == entry.dos_time && dos_date == entry.dos_date && name_size == name.bytesize &&
          (local == expected || (descriptor && local.all?(&:zero?))) &&
          @file.pos + name_size + extra_size + entry.compressed <= limit && read_exact(name_size) == name
        check_extra!(read_exact(extra_size))
        write_file(entry, root) unless entry.directory
        if descriptor
          raise INVALID, "zip_descriptor" if @file.pos + 12 > limit
          first = read_exact(4).unpack1("V")
          values = first == 0x08074b50 ? read_exact(12).unpack("VVV") : [ first, *read_exact(8).unpack("VV") ]
          raise INVALID, "zip_descriptor" unless values == expected && @file.pos <= limit
        end
        @file.pos
      end

      def write_file(entry, root)
        path = File.join(root, entry.name)
        FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
        File.open(path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |output|
          output.binmode
          size = 0
          crc = 0
          emit = lambda do |bytes|
            check_time!
            size += bytes.bytesize
            raise INVALID, "zip_expanded_size" if size > entry.expanded
            crc = Zlib.crc32(bytes, crc)
            output.write(bytes)
          end
          stream(entry, &emit)
          raise INVALID, "zip_checksum" unless size == entry.expanded && crc == entry.crc
        end
      end

      def stream(entry, &emit)
        remaining = entry.compressed
        inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS) if entry.method == 8
        while remaining.positive?
          check_time!
          raise INVALID, "zip_deflate_range" if inflater&.finished?
          bytes = read_exact([ remaining, 4096 ].min)
          remaining -= bytes.bytesize
          inflater ? inflater.inflate(bytes, &emit) : emit.call(bytes)
        end
        if inflater && (!inflater.finished? || inflater.total_in != entry.compressed)
          raise INVALID, "zip_deflate_range"
        end
      ensure
        inflater&.close
      end

      def read_exact(size)
        return "".b if size.zero?
        bytes = @file.read(size)
        raise INVALID, "zip_truncated" unless bytes && bytes.bytesize == size
        bytes
      end

      def check_time!
        raise INVALID, "zip_deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= @deadline
      end
    end
  end
end
