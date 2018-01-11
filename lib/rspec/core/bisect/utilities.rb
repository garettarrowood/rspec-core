module RSpec
  module Core
    module Bisect
      # @private
      ExampleSetDescriptor = Struct.new(:all_example_ids, :failed_example_ids)

      # @private
      class BisectFailedError < StandardError
        def self.for_failed_spec_run(spec_output)
          new("Failed to get results from the spec run. Spec run output:\n\n" +
              spec_output)
        end
      end

      # @private
      class Channel
        def self.new_pair
          from_a, to_b = IO.pipe
          from_b, to_a = IO.pipe

          return new(from_a, to_a), new(from_b, to_b)
        end

        def initialize(read_io, write_io)
          @read_io = read_io
          @write_io = write_io
        end

        def send(message)
          packet = Marshal.dump(message)
          @write_io.write("#{packet.bytesize}\n#{packet}")
        end

        def receive
          packet_size = Integer(@read_io.gets)
          Marshal.load(@read_io.read(packet_size))
        end

        def close
          @read_io.close
          @write_io.close
        end
      end
    end
  end
end
