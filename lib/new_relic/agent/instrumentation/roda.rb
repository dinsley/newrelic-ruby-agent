# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/newrelic-ruby-agent/blob/main/LICENSE for complete details.
# frozen_string_literal: true

require_relative 'roda/instrumentation'

DependencyDetection.defer do
  named :roda

  depends_on do
    defined?(Roda) &&
      Gem::Version.new(Roda::RodaVersion) >= Gem::Version.new('3.19.0') &&
      Roda::RodaPlugins::Base::ClassMethods.private_method_defined?(:build_rack_app) &&
      Roda::RodaPlugins::Base::InstanceMethods.method_defined?(:_roda_handle_main_route)
  end

  executes do
    if use_prepend?
      require_relative 'roda/prepend'
      prepend_instrument Roda.singleton_class, NewRelic::Agent::Instrumentation::Roda::Build::Prepend
    else
      require_relative 'roda/chain'
      chain_instrument NewRelic::Agent::Instrumentation::Roda::Build::Chain
    end
  end

  executes do
    NewRelic::Agent.logger.info('Installing Roda instrumentation')

    if use_prepend?
      require_relative 'roda/prepend'
      prepend_instrument Roda, NewRelic::Agent::Instrumentation::Roda::Prepend
    else
      require_relative 'roda/chain'
      chain_instrument NewRelic::Agent::Instrumentation::Roda::Chain
    end
  end
end
