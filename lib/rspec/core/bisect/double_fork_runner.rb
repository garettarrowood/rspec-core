require 'stringio'
RSpec::Support.require_rspec_core "formatters/base_bisect_formatter"
RSpec::Support.require_rspec_core "bisect/utilities"

module RSpec
  module Core
    module Bisect
      # TODO: docs
      # @private
      class DoubleForkRunner
        def self.start(shell_command)
          instance = new(shell_command)
          yield instance
        ensure
          instance.shutdown
        end

        def initialize(shell_command)
          @shell_command = shell_command

          @channel, child_channel = Channel.new_pair

          @child_pid = fork do
            @channel.close
            RSpec.reset

            RunDispatcher.new(
              child_channel,
              @shell_command.original_cli_args,
            ).dispatch_specs_loop

            exit!
          end

          child_channel.close
        end

        def run(locations)
          run_locations(ExampleSetDescriptor.new(locations,
            original_results.failed_example_ids))
        end

        def original_results
          @original_results ||= run_locations(ExampleSetDescriptor.new(
            @shell_command.original_locations, []))
        end

        def shutdown
          @channel.send(:exit)
          Process.waitpid(@child_pid)
        end

      private

        def run_locations(run_descriptor)
          @channel.send(run_descriptor)
          @channel.receive.tap do |result|
            if result.is_a?(String)
              raise BisectFailedError.for_failed_spec_run(result)
            end
          end
        end

        class RunDispatcher
          def initialize(channel, original_cli_args)
            @channel = channel
            @spec_output = StringIO.new
            $stdout = $stderr = @spec_output
            options = ConfigurationOptions.new(original_cli_args)
            @runner = Runner.new(options)
            @runner.load_config(@spec_output, @spec_output)
            # TODO: consider running `before(:suite)` hooks
          end

          def dispatch_specs_loop
            loop do
              message = @channel.receive
              break if message == :exit
              pid = fork { run_specs(message); exit! }
              Process.waitpid(pid)
            end
          end

        private

          def run_specs(run_descriptor)
            formatter = CaptureFormatter.new(run_descriptor.failed_example_ids)

            RSpec.configure do |c|
              c.files_or_directories_to_run = run_descriptor.all_example_ids
              c.formatter = formatter
              c.load_spec_files
            end

            # `announce_filters` has the side effect of implementing the logic
            # that honors `config.run_all_when_everything_filtered` so we need
            # to call it here. When we remove `run_all_when_everything_filtered`
            # (slated for RSpec 4), we can remove this call to `announce_filters`.
            RSpec.world.announce_filters

            @runner.run_specs
            latest_run_results = formatter.results

            if latest_run_results.nil? || latest_run_results.all_example_ids.empty?
              @channel.send(@spec_output.string)
            else
              @channel.send(latest_run_results)
            end
          end
        end

        class CaptureFormatter < Formatters::BaseBisectFormatter
          attr_accessor :results
          alias_method :notify_results, :results=
        end
      end
    end
  end
end
