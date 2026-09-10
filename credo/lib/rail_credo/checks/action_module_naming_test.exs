defmodule RailCredo.Checks.ActionModuleNamingTest do
  use Credo.Test.Case, async: true

  alias RailCredo.Checks.ActionModuleNaming

  test "allows valid action module with matching function and filename" do
    """
    defmodule Rail.Banks.Actions.CreateBankConnection do
      def create_bank_connection(scope, attrs) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/banks/actions/create_bank_connection.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "allows predicate function with ? suffix" do
    """
    defmodule Rail.Users.Actions.Can do
      def can?(scope, resource, action) do
        true
      end
    end
    """
    |> to_source_file("lib/rail/users/actions/can.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "allows bang function with ! suffix" do
    """
    defmodule Rail.Sales.Actions.UpsertOrderCategory do
      def upsert_order_category!(scope, attrs) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/sales/actions/upsert_order_category.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "handles acronyms like OAuth gracefully" do
    """
    defmodule Rail.Users.Actions.RegisterOAuthUser do
      def register_oauth_user(attrs) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/users/actions/register_oauth_user.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "allows function with guard clause" do
    """
    defmodule Rail.AuditLog.Actions.ForDelete do
      def for_delete(resource, scope) when is_struct(resource) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/audit_log/actions/for_delete.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "does not check non-action modules" do
    """
    defmodule Rail.Banks.Schemas.BankConnection do
      def some_unrelated_function do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/banks/schemas/bank_connection.ex")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "skips .exs files" do
    """
    defmodule Rail.Banks.Actions.CreateBankConnectionTest do
      def wrong_function do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/banks/actions/create_bank_connection_test.exs")
    |> run_check(ActionModuleNaming)
    |> refute_issues()
  end

  test "flags action module missing the expected public function" do
    """
    defmodule Rail.Banks.Actions.CreateBankConnection do
      def wrong_function(scope, attrs) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/banks/actions/create_bank_connection.ex")
    |> run_check(ActionModuleNaming)
    |> assert_issue(fn issue ->
      assert issue.message =~ "create_bank_connection"
    end)
  end

  test "flags action module with wrong filename" do
    """
    defmodule Rail.Shared.Actions.ParseTemplate do
      def parse_template(arg) do
        :ok
      end
    end
    """
    |> to_source_file("lib/rail/shared/actions/chart_of_accounts_preview.ex")
    |> run_check(ActionModuleNaming)
    |> assert_issue(fn issue ->
      assert issue.message =~ "parse_template.ex"
      assert issue.message =~ "chart_of_accounts_preview.ex"
    end)
  end
end
