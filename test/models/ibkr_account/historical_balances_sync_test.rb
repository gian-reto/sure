require "test_helper"

class IbkrAccount::HistoricalBalancesSyncTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "CHF",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account = @family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "CHF",
      current_balance: 3351,
      cash_balance: 1000.5,
      raw_equity_summary_payload: [
        { currency: "CHF", report_date: "2026-05-07", total: "3201.00" },
        { currency: "CHF", report_date: "2026-05-08", total: "3351.00" }
      ]
    )
    @ibkr_account.ensure_account_provider!(@account)
  end

  test "overrides IBKR totals while preserving materializer cash split" do
    seed_balance(date: Date.new(2026, 5, 7), balance: "3000.00", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 8), balance: "3100.00", cash_balance: "1000.50")

    assert_no_difference "@account.entries.count" do
      sync_at Date.new(2026, 5, 8)
    end

    first_balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    second_balance = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("3201.0"), first_balance.end_balance
    assert_equal BigDecimal("900.5"), first_balance.end_cash_balance
    assert_equal BigDecimal("2300.5"), first_balance.end_non_cash_balance

    assert_equal BigDecimal("3351.0"), second_balance.end_balance
    assert_equal BigDecimal("1000.5"), second_balance.end_cash_balance
    assert_equal BigDecimal("2350.5"), second_balance.end_non_cash_balance
    assert_equal BigDecimal("900.5"), second_balance.start_cash_balance
    assert_equal BigDecimal("2300.5"), second_balance.start_non_cash_balance
  end

  test "fills missing non trading dates with previous IBKR total and materializer cash" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "CHF", report_date: "2026-05-08", total: "3351.00" },
        { currency: "CHF", report_date: "2026-05-11", total: "3400.00" }
      ]
    )

    seed_balance(date: Date.new(2026, 5, 8), balance: "3351.00", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 9), balance: "900.50", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 10), balance: "900.50", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 11), balance: "3400.00", cash_balance: "910.00")

    sync_at Date.new(2026, 5, 11)

    saturday = @account.balances.find_by!(date: Date.new(2026, 5, 9), currency: "CHF")
    sunday = @account.balances.find_by!(date: Date.new(2026, 5, 10), currency: "CHF")

    assert_equal BigDecimal("3351.0"), saturday.end_balance
    assert_equal BigDecimal("900.5"), saturday.end_cash_balance
    assert_equal BigDecimal("2450.5"), saturday.end_non_cash_balance

    assert_equal BigDecimal("3351.0"), sunday.end_balance
    assert_equal BigDecimal("900.5"), sunday.end_cash_balance
    assert_equal BigDecimal("2450.5"), sunday.end_non_cash_balance
  end

  test "fills trailing non trading dates through current anchor date" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        { currency: "CHF", report_date: "2026-05-08", total: "3351.00" }
      ]
    )

    seed_balance(date: Date.new(2026, 5, 8), balance: "3351.00", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 9), balance: "900.50", cash_balance: "900.50")
    seed_balance(date: Date.new(2026, 5, 10), balance: "900.50", cash_balance: "900.50")

    sync_at Date.new(2026, 5, 10)

    saturday = @account.balances.find_by!(date: Date.new(2026, 5, 9), currency: "CHF")
    sunday = @account.balances.find_by!(date: Date.new(2026, 5, 10), currency: "CHF")

    assert_equal BigDecimal("3351.0"), saturday.end_balance
    assert_equal BigDecimal("3351.0"), sunday.end_balance
    assert_equal BigDecimal("900.5"), saturday.end_cash_balance
    assert_equal BigDecimal("900.5"), sunday.end_cash_balance
  end

  test "accepts equity summary rows when stored account currency casing differs" do
    @ibkr_account.update!(currency: "chf")

    sync_at Date.new(2026, 5, 8)

    first_balance = @account.balances.find_by!(date: Date.new(2026, 5, 7), currency: "CHF")
    second_balance = @account.balances.find_by!(date: Date.new(2026, 5, 8), currency: "CHF")

    assert_equal BigDecimal("3201.0"), first_balance.end_balance
    assert_equal BigDecimal("3351.0"), second_balance.end_balance
  end

  test "skips malformed equity summary rows and still imports valid rows" do
    @ibkr_account.update!(
      raw_equity_summary_payload: [
        nil,
        "bad-row",
        [],
        { currency: "CHF", report_date: "2026-05-09", total: "3400.00" }
      ]
    )
    seed_balance(date: Date.new(2026, 5, 9), balance: "3300.00", cash_balance: "1100.50")

    assert_nothing_raised do
      sync_at Date.new(2026, 5, 9)
    end

    balance = @account.balances.find_by!(date: Date.new(2026, 5, 9), currency: "CHF")

    assert_equal BigDecimal("3400.0"), balance.end_balance
    assert_equal BigDecimal("1100.5"), balance.end_cash_balance
    assert_equal BigDecimal("2299.5"), balance.end_non_cash_balance
  end

  private

    def seed_balance(date:, balance:, cash_balance:)
      balance = BigDecimal(balance)
      cash_balance = BigDecimal(cash_balance)
      non_cash_balance = balance - cash_balance

      @account.balances.create!(
        date: date,
        balance: balance,
        cash_balance: cash_balance,
        currency: "CHF",
        start_cash_balance: cash_balance,
        start_non_cash_balance: non_cash_balance,
        cash_inflows: 0,
        cash_outflows: 0,
        non_cash_inflows: 0,
        non_cash_outflows: 0,
        net_market_flows: 0,
        cash_adjustments: 0,
        non_cash_adjustments: 0,
        flows_factor: 1
      )
    end

    def sync_at(date)
      travel_to date do
        IbkrAccount::HistoricalBalancesSync.new(@ibkr_account).sync!
      end
    end
end
