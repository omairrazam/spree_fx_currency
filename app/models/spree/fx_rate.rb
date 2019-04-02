require 'fixer_client'

module Spree
  class FxRate < Spree::Base
    validates :from_currency, presence: true
    validates :to_currency, presence: true

    validates :rate, numericality: {
      greater_than_or_equal_to: 0
    }

    after_save :update_products_prices

    def self.spree_currency
      Spree::Config.currency
    end

    def self.supported_currencies
      Spree::Config.supported_currencies.split(', ')
                   .reject { |c| spree_currency.to_s == c.upcase }
    rescue NoMethodError => _e
      []
    end

    def self.sync_currencies_from_config
      found_currencies = Spree::FxRate.supported_currencies.map do |c|
        Spree::FxRate.find_or_create_by(from_currency: Spree::FxRate.spree_currency, to_currency: c.upcase).id
      end
      #where.not(id: found_currencies).destroy_all
    end

    def self.create_supported_currencies
      return unless table_exists?
      sync_currencies_from_config
      # fetch_fixer if Rails.env.production?
    end

    def self.fetch_fixer
      request = FixerClient.new(spree_currency, pluck(:to_currency))
      request.fetch.each do |currency, value|
        find_by(to_currency: currency).try(:update_attributes, rate: value)
      end
      true
    end

    def fetch_fixer
      request = FixerClient.new(from_currency, [to_currency])
      new_rate = request.fetch
      return false unless new_rate
      update_attributes(rate: new_rate)
    end

    # @todo: implement force option for only applying
    #        fx rate changes to blank prices
    def update_products_prices
      Spree::Product.transaction do
        Spree::Product.all.each { |p| update_prices_for_product(p) }

        Spree::SalePrice.transaction do
          Spree::SalePrice.all.each { |p| update_sale_price(p) }
        end
      end


    end

    def update_prices_for_product(product)
      product.variants_including_master.each do |variant|
        update_prices_for_variant(variant)
      end
    end

    def update_prices_for_variant(variant)
      from_price = variant.price_in(from_currency.upcase)
      return if from_price.new_record?

      new_price = variant.price_in(to_currency.split(',').first.upcase)
      new_price.amount = from_price.amount * rate
      new_price.save! if new_price.changed?
    end

    def update_sale_price(sale_price)
      return unless to_currency.split(',').first.upcase == sale_price.currency.upcase
      base_value = sale_price.price.variant.prices.where(currency:"AED").last.active_sale.value
      sale_price.value = base_value * rate
      sale_price.save! if sale_price.changed?
    end
  end
end
