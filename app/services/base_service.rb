# frozen_string_literal: true

class BaseService
  include AfterCommitEverywhere

  # rubocop:disable ThreadSafety/ClassAndModuleAttributes
  class_attribute :activity_log_config, instance_writer: false, default: nil
  # rubocop:enable ThreadSafety/ClassAndModuleAttributes
  class FailedResult < StandardError
    attr_reader :result, :original_error

    def initialize(result, message, original_error: nil)
      @result = result
      @original_error = original_error

      super(message)
    end
  end

  class ThrottlingError < StandardError
    attr_reader :provider_name

    def initialize(provider_name: nil)
      @provider_name = provider_name

      super(message)
    end

    def message
      "Service #{provider_name} is not available. Try again later."
    end
  end

  class NotFoundFailure < FailedResult
    attr_reader :resource

    def initialize(result, resource:)
      @resource = resource

      super(result, error_code)
    end

    def error_code
      "#{resource}_not_found"
    end
  end

  class MethodNotAllowedFailure < FailedResult
    attr_reader :code

    def initialize(result, code:)
      @code = code

      super(result, code)
    end
  end

  class ValidationFailure < FailedResult
    attr_reader :messages

    def initialize(result, messages:)
      @messages = messages

      super(result, format_messages)
    end

    private

    def format_messages
      "Validation errors: #{messages.to_json}"
    end
  end

  class ServiceFailure < FailedResult
    attr_reader :code, :error_message

    def initialize(result, code:, error_message:, original_error: nil)
      @code = code
      @error_message = error_message

      super(result, "#{code}: #{error_message}", original_error:)
    end
  end

  class UnknownTaxFailure < FailedResult
    attr_reader :code, :error_message

    def initialize(result, code:, error_message:)
      @code = code
      @error_message = error_message

      super(result, "#{code}: #{error_message}")
    end
  end

  class ForbiddenFailure < FailedResult
    attr_reader :code

    def initialize(result, code:)
      @code = code

      super(result, code)
    end
  end

  class UnauthorizedFailure < FailedResult
    def initialize(result, message:)
      super(result, message)
    end
  end

  class ProviderFailure < FailedResult
    attr_reader :provider

    def initialize(result, provider:, error:)
      @provider = provider
      super(result, nil, original_error: error)
    end
  end

  class ThirdPartyFailure < FailedResult
    attr_reader :third_party, :error_code, :error_message

    def initialize(result, third_party:, error_code:, error_message:)
      @third_party = third_party
      @error_message = error_message
      @error_code = error_code

      super(result, "#{third_party}: #{error_code} - #{error_message}")
    end
  end

  class TooManyProviderRequestsFailure < FailedResult
    attr_reader :provider_name, :error

    def initialize(result, provider_name:, error:)
      @provider_name = provider_name
      @error = error

      super(result, error.message, original_error: error)
    end
  end

  # DEPRECATED: This is a legacy result class that should
  #             be replaced be defining a Result in every service, using the BaseResult
  class LegacyResult < OpenStruct
    attr_reader :error

    def initialize
      super

      @failure = false
      @error = nil
    end

    def success?
      !failure
    end

    def failure?
      failure
    end

    def fail_with_error!(error)
      @failure = true
      @error = error

      self
    end

    def not_found_failure!(resource:)
      fail_with_error!(NotFoundFailure.new(self, resource:))
    end

    def not_allowed_failure!(code:)
      fail_with_error!(MethodNotAllowedFailure.new(self, code:))
    end

    def record_validation_failure!(record:)
      validation_failure!(errors: record.errors.messages)
    end

    def validation_failure!(errors:)
      fail_with_error!(ValidationFailure.new(self, messages: errors))
    end

    def single_validation_failure!(error_code:, field: :base)
      validation_failure!(errors: {field.to_sym => [error_code]})
    end

    def service_failure!(code:, message:, error: nil)
      fail_with_error!(ServiceFailure.new(self, code:, error_message: message, original_error: error))
    end

    def unknown_tax_failure!(code:, message:)
      fail_with_error!(UnknownTaxFailure.new(self, code:, error_message: message))
    end

    def forbidden_failure!(code: "feature_unavailable")
      fail_with_error!(ForbiddenFailure.new(self, code:))
    end

    def unauthorized_failure!(message: "unauthorized")
      fail_with_error!(UnauthorizedFailure.new(self, message:))
    end

    def provider_failure!(provider:, error:)
      fail_with_error!(ProviderFailure.new(self, provider:, error:))
    end

    def third_party_failure!(third_party:, error_code:, error_message:)
      fail_with_error!(ThirdPartyFailure.new(self, third_party:, error_code:, error_message:))
    end

    def too_many_provider_requests_failure!(provider_name:, error:)
      fail_with_error!(TooManyProviderRequestsFailure.new(self, provider_name:, error:))
    end

    def raise_if_error!
      return self if success?

      raise(error)
    end

    private

    attr_accessor :failure
  end

  Result = LegacyResult

  def self.activity_loggable(action:, record:, condition: -> { true }, after_commit: true)
    self.activity_log_config = {action:, record:, condition:, after_commit:}
  end

  def self.call(*, **, &)
    LagoTracer.in_span("#{name}#call") do
      instance = new(*, **)

      if instance.try(:produce_activity_log?)
        instance.call_with_activity_log(&)
      else
        instance.call(&)
      end
    end
  end

  def self.call_async(*, **, &)
    LagoTracer.in_span("#{name}#call_async") do
      new(*, **).call_async(&)
    end
  end

  def self.call!(*, **, &)
    call(*, **, &).raise_if_error!
  end

  def initialize(args = nil)
    @result = self.class::Result.new
    @source = CurrentContext&.source
  end

  def call(**args, &block)
    raise NotImplementedError
  end

  def call!(*, &)
    call(*, &).raise_if_error!
  end

  def call_async(**args, &block)
    raise NotImplementedError
  end

  def produce_activity_log?
    return false if activity_log_config.nil?

    instance_exec(&self.class.activity_log_config[:condition])
  end

  def call_with_activity_log(&block)
    action = self.class.activity_log_config[:action]
    after_commit = self.class.activity_log_config[:after_commit]
    kwargs = {after_commit:}.compact

    case action
    when /updated/
      record = instance_exec(&self.class.activity_log_config[:record])
      Utils::ActivityLog.produce(record, action, **kwargs) { call(&block) }
    else
      call(&block).tap do |result|
        record = instance_exec(&self.class.activity_log_config[:record])
        Utils::ActivityLog.produce(record, action, **kwargs) { result }
      end
    end
  end

  protected

  attr_writer :result

  private

  attr_reader :result, :source

  def api_context?
    source&.to_sym == :api
  end

  def graphql_context?
    source&.to_sym == :graphql
  end

  def at_time_zone(customer: "customers", billing_entity: "billing_entities")
    Utils::Timezone.at_time_zone_sql(customer:, billing_entity:)
  end
end
