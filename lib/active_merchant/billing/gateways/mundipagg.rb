module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class MundipaggGateway < Gateway
      self.test_url = 'https://api.mundipagg.com/core/v1/'
      self.live_url = 'https://api.mundipagg.com/core/v1/'

      self.supported_countries = ['US']
      self.default_currency = 'USD'
      self.supported_cardtypes = [:visa, :master, :american_express, :discover]

      self.homepage_url = 'https://www.mundipagg.com/'
      self.display_name = 'Mundipagg'

      STANDARD_ERROR_CODE_MAPPING = {}

      def initialize(options={})
        requires!(options, :api_key)
        super
      end

      def purchase(money, payment, options={})
        post = {}
        add_invoice(post, money, options)
        add_customer_data(post, options)
        add_shipping_address(post, options)
        add_payment(post, payment, options)

        commit('sale', post)
      end

      def authorize(money, payment, options={})
        post = {}
        add_invoice(post, money, options)
        add_customer_data(post, options)
        add_shipping_address(post, options)
        add_payment(post, payment, options)
        add_capture_flag(post, payment)
        commit('authonly', post)
      end

      def capture(money, authorization, options={})
        commit('capture', post={}, authorization)
      end

      def refund(money, authorization, options={})
        add_invoice(post={}, money, options)
        commit('refund', post, authorization)
      end

      def void(authorization, options={})
        commit('void', post=nil, authorization)
      end

      def verify(credit_card, options={})
        MultiResponse.run(:use_first_response) do |r|
          r.process { authorize(100, credit_card, options) }
          r.process(:ignore_result) { void(r.authorization, options) }
        end
      end

      def supports_scrubbing?
        true
      end

      def scrub(transcript)
        transcript
      end

      private

      def add_customer_data(post, options)
        post[:customer] = {}
        post[:customer][:email] = options[:email]
      end

      def add_billing_address(post, options)
        billing = {}
        address = options[:billing_address] || options[:address]
        billing[:street] = address[:address1].match(/\D+/)[0].strip if address[:address1]
        billing[:number] = address[:address1].match(/\d+/)[0] if address[:address1]
        billing[:compliment] = address[:address2] if address[:address2]
        billing[:city] = address[:city] if address[:city]
        billing[:state] = address[:state] if address[:state]
        billing[:country] = address[:country] if address[:country]
        billing[:zip_code] = address[:zip] if address[:zip]
        billing[:neighborhood] = address[:neighborhood]
        billing
      end

      def add_shipping_address(post, options)
        if address = options[:shipping_address]
          post[:address] = {}
          post[:address][:street] = address[:address1].match(/\D+/)[0].strip if address[:address1]
          post[:address][:number] = address[:address1].match(/\d+/)[0] if address[:address1]
          post[:address][:compliment] = address[:address2] if address[:address2]
          post[:address][:city] = address[:city] if address[:city]
          post[:address][:state] = address[:state] if address[:state]
          post[:address][:country] = address[:country] if address[:country]
          post[:address][:zip_code] = address[:zip] if address[:zip]
        end
      end

      def add_invoice(post, money, options)
        post[:amount] = money
        post[:currency] = (options[:currency] || currency(money))
      end

      def add_capture_flag(post, payment)
        if card_brand(payment) == 'voucher'
          post[:payment][:voucher][:capture] = false
        else
          post[:payment][:credit_card][:capture] = false
        end
      end

      def add_payment(post, payment, options)
        post[:customer][:name] = payment.name
        post[:payment] = {}
        if card_brand(payment) == 'voucher'
          add_voucher(post, payment, options)
        else
          add_credit_card(post, payment, options)
        end
      end

      def add_credit_card(post, payment, options)
        post[:payment][:payment_method] = "credit_card"
        post[:payment][:credit_card] = {}
        post[:payment][:credit_card][:card] = {}
        post[:payment][:credit_card][:card][:number] = payment.number
        post[:payment][:credit_card][:card][:holder_name] = payment.name
        post[:payment][:credit_card][:card][:exp_month] = payment.month
        post[:payment][:credit_card][:card][:exp_year] = payment.year
        post[:payment][:credit_card][:card][:cvv] = payment.verification_value
        post[:payment][:credit_card][:card][:billing_address] = add_billing_address(post, options)
      end

      def add_voucher(post, payment, options)
        post[:payment][:payment_method] = "voucher"
        post[:payment][:voucher] = {}
        post[:payment][:voucher][:card] = {}
        post[:payment][:voucher][:card][:number] = payment.number
        post[:payment][:voucher][:card][:holder_name] = payment.name
        post[:payment][:voucher][:card][:holder_document] = options[:holder_document]
        post[:payment][:voucher][:card][:exp_month] = payment.month
        post[:payment][:voucher][:card][:exp_year] = payment.year
        post[:payment][:voucher][:card][:cvv] = payment.verification_value
        post[:payment][:voucher][:card][:billing_address] = add_billing_address(post, options)
      end
      
      def headers
        {
          'Authorization' => 'Basic ' + Base64.strict_encode64("#{@options[:api_key]}:"),
          'Content-Type' => 'application/json',
          'Accept' => 'application/json'
        }
      end

      def parse(body)
        JSON.parse(body)
      end

      def url_for(action, auth=nil)
        url = (test? ? test_url : live_url) + 'charges/'
        if %w(refund void capture).include? action
          url += "#{auth}/"
        end
        if action == 'capture'
          url += 'capture/'
        end
        url
      end

      def commit(action, parameters, auth = nil)
        url = url_for(action, auth) 
        puts url
        if action == 'void'
          response = parse(ssl_request(:delete, url, nil, headers))
        else
          response = parse(ssl_post(url, post_data(parameters), headers))
        end

        Response.new(
          success_from(response),
          message_from(response),
          response,
          authorization: authorization_from(response),
          avs_result: AVSResult.new(code: response["some_avs_response_key"]),
          cvv_result: CVVResult.new(response["some_cvv_response_key"]),
          test: test?,
          error_code: error_code_from(response)
        )
        rescue ResponseError => e
          case e.response.code
          when '400'
            return Response.new(false, 'Invalid request', {}, :test => test?)
          when '401'
            return Response.new(false, 'Invalid API key', {}, :test => test?)
          when '404'
            return Response.new(false, 'The requested resource does not exist', {}, :test => test?)
          when '412'
            return Response.new(false, 'Valid parameters but request failed', {}, :test => test?)
          when '422'
            return Response.new(false, 'Invalid parameters', {}, :test => test?)
          when '500'
            return Response.new(false, 'An internal error occurred', {}, :test => test?)
            if e.response.body.split(' ')[0] == 'validation'
              return Response.new(false, e.response.body.split(' ', 3)[2], {}, :test => test?)
            end
          end
          raise

      end

      def success_from(response)
        %w[pending paid processing voided].include? response["status"]
      end

      def message_from(response)
        return response["message"] if response["message"]
        return response["last_transaction"]["acquirer_message"]
      end

      def authorization_from(response)
        response["id"]
      end

      def post_data(parameters = {})
        parameters.to_json
      end

      def error_code_from(response)
        unless success_from(response)
          # TODO: lookup error code for this response
        end
      end
    end
  end
end
