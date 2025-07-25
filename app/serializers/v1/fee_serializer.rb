# frozen_string_literal: true

module V1
  class FeeSerializer < ModelSerializer
    def serialize
      subunit_to_unit = model.amount.currency.subunit_to_unit.to_d

      payload = {
        lago_id: model.id,
        lago_charge_id: model.charge_id,
        lago_charge_filter_id: model.charge_filter_id,
        lago_invoice_id: model.invoice_id,
        lago_true_up_fee_id: model.true_up_fee&.id,
        lago_true_up_parent_fee_id: model.true_up_parent_fee_id,
        lago_subscription_id: model.subscription_id,
        external_subscription_id: model.subscription&.external_id,
        lago_customer_id: model.customer&.id,
        external_customer_id: model.customer&.external_id,
        item: {
          type: model.fee_type,
          code: model.item_code,
          name: model.item_name,
          description: model.item_description,
          invoice_display_name: model.invoice_name,
          filters: model.charge_filter&.to_h,
          filter_invoice_display_name: model.charge_filter&.display_name,
          lago_item_id: model.item_id,
          item_type: model.item_type,
          grouped_by: model.grouped_by
        },
        pay_in_advance:,
        invoiceable:,
        amount_cents: model.amount_cents,
        amount_currency: model.amount_currency,
        precise_amount: model.precise_amount_cents.fdiv(subunit_to_unit),
        precise_total_amount: model.precise_total_amount_cents.fdiv(subunit_to_unit),
        taxes_amount_cents: model.taxes_amount_cents,
        taxes_precise_amount: model.taxes_precise_amount_cents.fdiv(subunit_to_unit),
        taxes_rate: model.taxes_rate,
        total_amount_cents: model.total_amount_cents,
        total_amount_currency: model.amount_currency,
        units: model.units,
        description: model.description,
        precise_unit_amount: model.precise_unit_amount,
        precise_coupons_amount_cents: model.precise_coupons_amount_cents,
        events_count: model.events_count,
        payment_status: model.payment_status,
        created_at: model.created_at&.iso8601,
        succeeded_at: model.succeeded_at&.iso8601,
        failed_at: model.failed_at&.iso8601,
        refunded_at: model.refunded_at&.iso8601,
        amount_details: model.amount_details,
        self_billed: model.invoice&.self_billed || false,
        pricing_unit_details:
      }

      payload.merge!(date_boundaries) if model.charge? || model.subscription?
      payload.merge!(pay_in_advance_charge_attributes) if model.pay_in_advance?
      payload.merge!(applied_taxes) if include?(:applied_taxes)

      payload
    end

    private

    def date_boundaries
      if model.charge? && !model.pay_in_advance? && model.charge.pay_in_advance?
        subscription = model.subscription
        timestamp = model.invoice.invoice_subscription(subscription.id).timestamp
        interval = ::Subscriptions::DatesService.charge_pay_in_advance_interval(timestamp, subscription)

        return {
          from_date: interval[:charges_from_date]&.to_datetime&.iso8601,
          to_date: interval[:charges_to_date]&.to_datetime&.end_of_day&.iso8601
        }
      end

      if model.charge? && !model.charge.invoiceable? && model.pay_in_advance?
        timestamp = Time.parse(model.properties["timestamp"]).to_i
        interval = ::Subscriptions::DatesService.charge_pay_in_advance_interval(timestamp, model.subscription)

        return {
          from_date: interval[:charges_from_date]&.to_datetime&.iso8601,
          to_date: interval[:charges_to_date]&.to_datetime&.end_of_day&.iso8601
        }
      end

      {
        from_date:,
        to_date:
      }
    end

    def from_date
      property = model.charge? ? "charges_from_datetime" : "from_datetime"
      model.properties[property]&.to_datetime&.iso8601
    end

    def to_date
      property = model.charge? ? "charges_to_datetime" : "to_datetime"
      model.properties[property]&.to_datetime&.iso8601
    end

    def pay_in_advance_charge_attributes
      return {} unless model.pay_in_advance?

      {event_transaction_id: model.pay_in_advance_event_transaction_id}
    end

    def applied_taxes
      ::CollectionSerializer.new(
        model.applied_taxes,
        ::V1::Fees::AppliedTaxSerializer,
        collection_name: "applied_taxes"
      ).serialize
    end

    def pay_in_advance
      if model.charge?
        model.pay_in_advance
      elsif model.subscription?
        model.subscription&.plan&.pay_in_advance
      else
        false
      end
    end

    def invoiceable
      model.charge? ? model.charge&.invoiceable : true
    end

    def pricing_unit_details
      return if model.pricing_unit_usage.nil?

      ::V1::PricingUnitUsageSerializer.new(model.pricing_unit_usage).serialize
    end
  end
end
