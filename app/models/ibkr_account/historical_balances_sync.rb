class IbkrAccount::HistoricalBalancesSync
  include IbkrAccount::DataHelpers

  attr_reader :ibkr_account

  def initialize(ibkr_account)
    @ibkr_account = ibkr_account
  end

  def sync!
    return unless account.present?
    return if normalized_rows.empty?

    account.balances.upsert_all(
      balance_rows,
      unique_by: %i[account_id date currency]
    )
  end

  private
    def account
      ibkr_account.current_account
    end

    def account_currency
      ibkr_account.currency.to_s.upcase
    end

    def normalized_rows
      @normalized_rows ||= begin
        existing_balances = account.balances
          .where(currency: account.currency)
          .index_by(&:date)

        reported_rows = Array(ibkr_account.raw_equity_summary_payload)
          .filter_map do |row|
            next unless row.is_a?(Hash)

            data = row.with_indifferent_access
            currency = data[:currency].presence&.upcase
            next if currency.present? && currency != account_currency

            date = parse_date(data[:report_date])
            total = parse_decimal(data[:total])
            next unless date && total

            cash = cash_balance_for(date, existing_balances)

            {
              date: date,
              total: total,
              cash: cash,
              non_cash: total - cash
            }
          end
          .sort_by { |row| row[:date] }

        fill_gaps(reported_rows, existing_balances)
      end
    end

    def fill_gaps(rows, existing_balances)
      return [] if rows.empty?

      rows_by_date = rows.index_by { |row| row[:date] }
      first_date = rows.first[:date]
      last_date = [ rows.last[:date], account.current_anchor_date || Date.current ].max

      last_total = nil
      (first_date..last_date).filter_map do |date|
        if rows_by_date[date]
          last_total = rows_by_date[date][:total]
          rows_by_date[date]
        else
          next unless last_total

          cash = cash_balance_for(date, existing_balances)

          {
            date: date,
            total: last_total,
            cash: cash,
            non_cash: last_total - cash
          }
        end
      end
    end

    def cash_balance_for(date, existing_balances)
      existing_balances[date]&.cash_balance || BigDecimal("0")
    end

    def balance_rows
      current_time = Time.current

      normalized_rows.each_with_index.map do |row, index|
        previous_row = index.zero? ? nil : normalized_rows[index - 1]
        start_cash_balance = previous_row ? previous_row[:cash] : row[:cash]
        start_non_cash_balance = previous_row ? previous_row[:non_cash] : row[:non_cash]

        {
          account_id: account.id,
          date: row[:date],
          balance: row[:total],
          cash_balance: row[:cash],
          currency: account.currency,
          start_cash_balance: start_cash_balance,
          start_non_cash_balance: start_non_cash_balance,
          cash_inflows: 0,
          cash_outflows: 0,
          non_cash_inflows: 0,
          non_cash_outflows: 0,
          net_market_flows: 0,
          cash_adjustments: row[:cash] - start_cash_balance,
          non_cash_adjustments: row[:non_cash] - start_non_cash_balance,
          flows_factor: 1,
          created_at: current_time,
          updated_at: current_time
        }
      end
    end
end
