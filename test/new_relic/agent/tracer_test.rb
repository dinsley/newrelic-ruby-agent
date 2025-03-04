# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative '../../test_helper'

module NewRelic
  module Agent
    class TracerTest < Minitest::Test
      def teardown
        NewRelic::Agent.instance.drop_buffered_data
      end

      def test_tracer_aliases
        state = Tracer.state

        refute_nil state
      end

      def test_current_transaction_with_transaction
        in_transaction do |txn|
          assert_equal txn, Tracer.current_transaction
        end
      end

      def test_current_transaction_without_transaction
        assert_nil Tracer.current_transaction
      end

      def test_trace_id_in_transaction
        in_transaction do |txn|
          refute_nil Tracer.trace_id
          assert_equal txn.trace_id, Tracer.trace_id
        end
      end

      def test_trace_id_not_in_transaction
        assert_nil Tracer.trace_id
      end

      def test_span_id_in_transaction
        in_transaction do |txn|
          refute_nil Tracer.span_id
          assert_equal txn.current_segment.guid, Tracer.span_id
        end
      end

      def test_span_id_not_in_transaction
        assert_nil Tracer.span_id
      end

      def test_sampled?
        # If DT is enabled, the Tracer yields the #sampled? result for the
        # underlying current transaction
        with_config(:'distributed_tracing.enabled' => true) do
          in_transaction do |txn|
            assert_equal txn.sampled?,
              Tracer.sampled?,
              'Tracer.sampled should match the #sampled? result for the current transaction'
          end
          in_transaction do |txn|
            txn.sampled = true

            assert_predicate Tracer, :sampled?
          end
          in_transaction do |txn|
            txn.sampled = false

            refute_predicate Tracer, :sampled?
          end
        end

        # If DT is disabled, Tracer.sampled? is always false
        with_config(:'distributed_tracing.enabled' => false) do
          in_transaction do |txn|
            refute_predicate Tracer, :sampled?
          end
        end
      end

      def test_sampled_not_in_transaction
        refute_predicate Tracer, :sampled?
      end

      def test_tracing_enabled
        NewRelic::Agent.disable_all_tracing do
          in_transaction do
            NewRelic::Agent.disable_all_tracing do
              refute_predicate Tracer, :tracing_enabled?
            end

            refute_predicate Tracer, :tracing_enabled?
          end
        end

        assert_predicate Tracer, :tracing_enabled?
      end

      def test_in_transaction
        NewRelic::Agent::Tracer.in_transaction(name: 'test', category: :other) do
          # No-op
        end

        assert_metrics_recorded(['test'])
      end

      def test_in_transaction_missing_category
        assert_raises ArgumentError do
          NewRelic::Agent::Tracer.in_transaction(name: 'test') do
            # No-op
          end
        end
      end

      def test_in_transaction_with_early_failure
        yielded = false
        NewRelic::Agent::Transaction.any_instance.stubs(:start).raises('Boom')
        NewRelic::Agent::Tracer.in_transaction(name: 'test', category: :other) do
          yielded = true
        end

        assert yielded

        NewRelic::Agent::Tracer.clear_state
      end

      def test_in_transaction_with_late_failure
        yielded = false
        NewRelic::Agent::Transaction.any_instance.stubs(:commit!).raises('Boom')
        NewRelic::Agent::Tracer.in_transaction(name: 'test', category: :other) do
          yielded = true
        end

        assert yielded
        refute_metrics_recorded(['test'])
      end

      def test_in_transaction_notices_errors
        assert_raises RuntimeError do
          NewRelic::Agent::Tracer.in_transaction(name: 'test', category: :other) do
            raise 'O_o'
          end
        end

        assert_metrics_recorded(['Errors/all'])
      end

      def test_start_transaction_without_one_already_existing
        assert_nil Tracer.current_transaction

        txn = Tracer.start_transaction(name: 'Controller/Blogs/index',
          category: :controller)

        assert_equal txn, Tracer.current_transaction

        txn.finish

        assert_nil Tracer.current_transaction
      end

      def test_start_transaction_returns_current_if_already_in_progress
        in_transaction do |txn1|
          refute_nil Tracer.current_transaction

          txn2 = Tracer.start_transaction(name: 'Controller/Blogs/index',
            category: :controller)

          assert_equal txn2, txn1
          assert_equal txn2, Tracer.current_transaction
        end
      end

      def test_start_transaction_or_segment_without_active_txn
        assert_nil Tracer.current_transaction

        finishable = Tracer.start_transaction_or_segment(
          name: 'Controller/Blogs/index',
          category: :controller
        )

        assert_equal finishable, Tracer.current_transaction

        finishable.finish

        assert_nil Tracer.current_transaction
      end

      def test_start_transaction_or_segment_with_active_txn
        in_transaction do |txn|
          finishable = Tracer.start_transaction_or_segment(
            name: 'Middleware/Rack/MyMiddleWare/call',
            category: :middleware
          )

          # TODO: Implement current_segment on Tracer
          assert_equal finishable, Tracer.current_transaction.current_segment

          finishable.finish

          refute_nil Tracer.current_transaction
        end

        assert_nil Tracer.current_transaction
      end

      def test_start_transaction_or_segment_multiple_calls
        f1 = Tracer.start_transaction_or_segment(
          name: 'Controller/Rack/Test::App/call',
          category: :rack
        )

        f2 = Tracer.start_transaction_or_segment(
          name: 'Middleware/Rack/MyMiddleware/call',
          category: :middleware
        )

        f3 = Tracer.start_transaction_or_segment(
          name: 'Controller/blogs/index',
          category: :controller
        )

        f4 = Tracer.start_segment(name: 'Custom/MyClass/my_meth')

        f4.finish
        f3.finish
        f2.finish
        f1.finish

        assert_metrics_recorded [
          ['Nested/Controller/Rack/Test::App/call', 'Controller/blogs/index'],
          ['Middleware/Rack/MyMiddleware/call', 'Controller/blogs/index'],
          ['Nested/Controller/blogs/index', 'Controller/blogs/index'],
          ['Custom/MyClass/my_meth', 'Controller/blogs/index'],
          'Controller/blogs/index',
          'Nested/Controller/Rack/Test::App/call',
          'Middleware/Rack/MyMiddleware/call',
          'Nested/Controller/blogs/index',
          'Custom/MyClass/my_meth'
        ]
      end

      def test_start_transaction_or_segment_multiple_calls_with_partial_name
        f1 = Tracer.start_transaction_or_segment(
          partial_name: 'Test::App/call',
          category: :rack
        )

        f2 = Tracer.start_transaction_or_segment(
          partial_name: 'MyMiddleware/call',
          category: :middleware
        )

        f3 = Tracer.start_transaction_or_segment(
          partial_name: 'blogs/index',
          category: :controller
        )

        f3.finish
        f2.finish
        f1.finish

        assert_metrics_recorded [
          ['Nested/Controller/Rack/Test::App/call', 'Controller/blogs/index'],
          ['Middleware/Rack/MyMiddleware/call', 'Controller/blogs/index'],
          ['Nested/Controller/blogs/index', 'Controller/blogs/index'],
          'Controller/blogs/index',
          'Nested/Controller/Rack/Test::App/call',
          'Middleware/Rack/MyMiddleware/call',
          'Nested/Controller/blogs/index'
        ]
      end

      def test_start_transaction_with_partial_name
        txn = Tracer.start_transaction(
          partial_name: 'Test::App/call',
          category: :rack
        )

        txn.finish

        assert_metrics_recorded ['Controller/Rack/Test::App/call']
      end

      def test_current_segment_with_transaction
        assert_nil Tracer.current_segment

        txn = Tracer.start_transaction(name: 'Controller/blogs/index', category: :controller)

        assert_equal txn.initial_segment, Tracer.current_segment

        segment = Tracer.start_segment(name: 'Custom/MyClass/myoperation')

        assert_equal segment, Tracer.current_segment

        txn.finish

        assert_nil Tracer.current_segment
      end

      def test_current_segment_without_transaction
        assert_nil Tracer.current_segment
        Tracer.start_segment(name: 'Custom/MyClass/myoperation')

        assert_nil Tracer.current_segment
      end

      def test_traced_threads_dont_keep_using_finished_transaction
        txn = Tracer.start_transaction(name: 'Controller/blogs/index', category: :controller)
        threads = []
        threads << Thread.new do
          Tracer.start_segment(name: 'Custom/MyClass/myoperation')
          sleep(0.01) until txn.finished?

          threads << Thread.new do
            assert_nil Tracer.current_transaction
          end
        end
        sleep(0.01) until txn.segments.size >= 2
        txn.finish
        threads.each(&:join)
      end

      def test_current_segment_in_nested_threads_with_traced_thread
        assert_nil Tracer.current_segment

        txn = Tracer.start_transaction(name: 'Controller/blogs/index', category: :controller)

        assert_equal txn.initial_segment, Tracer.current_segment
        threads = []

        threads << ::NewRelic::TracedThread.new do
          segment = Tracer.start_segment(name: 'Custom/MyClass/myoperation')

          assert_equal segment, Tracer.current_segment

          threads << ::NewRelic::TracedThread.new do
            segment2 = Tracer.start_segment(name: 'Custom/MyClass/myoperation2')

            assert_equal segment2, Tracer.current_segment
            segment2.finish
          end

          # make sure current segment is still the outer segment
          assert_equal segment, Tracer.current_segment
          segment.finish # finish thread segment
        end

        assert_equal txn.initial_segment, Tracer.current_segment
        threads.each(&:join)
        txn.finish

        assert_nil Tracer.current_segment
      end

      def test_current_segment_in_nested_threads_auto
        with_config(:'instrumentation.thread.tracing' => true) do
          assert_nil Tracer.current_segment

          txn = Tracer.start_transaction(name: 'Controller/blogs/index', category: :controller)

          assert_equal txn.initial_segment, Tracer.current_segment
          threads = []

          threads << ::Thread.new do
            segment = Tracer.start_segment(name: 'Custom/MyClass/myoperation')

            assert_equal segment, Tracer.current_segment

            threads << Thread.new do
              segment2 = Tracer.start_segment(name: 'Custom/MyClass/myoperation2')

              assert_equal segment2, Tracer.current_segment
              segment2.finish
            end

            # make sure current segment is still the outer segment
            assert_equal segment, Tracer.current_segment
            segment.finish # finish thread segment
          end

          assert_equal txn.initial_segment, Tracer.current_segment

          threads.each(&:join)
          txn.finish

          assert_equal 2, txn.segments.count { |s| s.name == 'Ruby/Thread' }
          assert_nil Tracer.current_segment
        end
      end

      def test_current_segment_in_nested_threads_disabled
        with_config(:'instrumentation.thread.tracing' => false) do
          assert_nil Tracer.current_segment

          txn = Tracer.start_transaction(name: 'Controller/blogs/index', category: :controller)

          assert_equal txn.initial_segment, Tracer.current_segment
          threads = []

          threads << ::Thread.new do
            # nothong
          end

          assert_equal txn.initial_segment, Tracer.current_segment
          threads.each(&:join)
          txn.finish

          assert_equal 0, txn.segments.count { |s| s.name == 'Ruby/Thread' }
          assert_nil Tracer.current_segment
        end
      end

      def test_thread_ids_included_when_enabled
        with_config(
          :'instrumentation.thread.tracing' => true,
          :'thread_ids_enabled' => true
        ) do
          txn = in_transaction do
            Thread.new { 'woof' }.join
          end

          assert_match %r{Ruby/Thread/Thread\d+/Fiber\d+}, txn.segments.last.name
        end
      end

      def test_thread_ids_absent_when_disabled
        with_config(
          :'instrumentation.thread.tracing' => true,
          :'thread_ids_enabled' => false
        ) do
          txn = in_transaction do
            Thread.new { 'woof' }.join
          end

          assert_match %r{Ruby/Thread$}, txn.segments.last.name
        end
      end

      def test_start_segment
        name = 'Custom/MyClass/myoperation'
        unscoped_metrics = [
          'Custom/Segment/something/all',
          'Custom/Segment/something/allWeb'
        ]
        parent = Transaction::Segment.new('parent')
        start_time = Process.clock_gettime(Process::CLOCK_REALTIME)

        in_transaction('test') do
          segment = Tracer.start_segment(
            name: name,
            unscoped_metrics: unscoped_metrics,
            parent: parent,
            start_time: start_time
          )

          assert_equal segment, Tracer.current_segment

          segment.finish
        end
      end

      def test_start_datastore_segment
        product = 'MySQL'
        operation = 'INSERT'
        collection = 'blogs'
        host = 'localhost'
        port_path_or_id = '3306'
        database_name = 'blog_app'
        start_time = Process.clock_gettime(Process::CLOCK_REALTIME)
        parent = Transaction::Segment.new('parent')

        in_transaction('test') do
          segment = Tracer.start_datastore_segment(
            product: product,
            operation: operation,
            collection: collection,
            host: host,
            port_path_or_id: port_path_or_id,
            database_name: database_name,
            start_time: start_time,
            parent: parent
          )

          assert_equal segment, Tracer.current_segment

          segment.finish
        end
      end

      def test_start_external_request_segment
        library = 'Net::HTTP'
        uri = 'https://docs.newrelic.com'
        procedure = 'GET'
        start_time = Process.clock_gettime(Process::CLOCK_REALTIME)
        parent = Transaction::Segment.new('parent')

        in_transaction('test') do
          segment = Tracer.start_external_request_segment(
            library: library,
            uri: uri,
            procedure: procedure,
            start_time: start_time,
            parent: parent
          )

          assert_equal segment, Tracer.current_segment

          segment.finish
        end
      end

      def test_accept_distributed_trace_payload_delegates_to_transaction
        payload = stub(payload: nil)
        in_transaction do |txn|
          txn.distributed_tracer.expects(:accept_distributed_trace_payload).with(payload)
          Tracer.accept_distributed_trace_payload(payload)
        end
      end

      def test_create_distributed_trace_payload_delegates_to_transaction
        in_transaction do |txn|
          txn.distributed_tracer.expects(:create_distributed_trace_payload)
          Tracer.create_distributed_trace_payload
        end
      end
    end
  end
end
