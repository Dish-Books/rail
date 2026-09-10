defmodule Rail.Backends.Actions.GetAccount do
  @moduledoc false

  alias Rail.Backends.Schemas.CliAccount
  alias Rail.Repo

  def get_account(backend) when is_atom(backend) or is_binary(backend) do
    get_account(nil, backend, [])
  end

  def get_account(scope, backend) when is_atom(backend) or is_binary(backend) do
    get_account(scope, backend, [])
  end

  def get_account(backend, opts) when (is_atom(backend) or is_binary(backend)) and is_list(opts) do
    get_account(nil, backend, opts)
  end

  def get_account(_scope, backend, opts) do
    node = Keyword.get(opts, :node) || CliAccount.default_node()

    case normalize_backend(backend) do
      {:ok, backend_val} ->
        Repo.get_by(CliAccount, node: node, backend: backend_val)

      :error ->
        nil
    end
  end

  defp normalize_backend(:claude), do: {:ok, :claude}
  defp normalize_backend("claude"), do: {:ok, :claude}
  defp normalize_backend(:agy), do: {:ok, :agy}
  defp normalize_backend("agy"), do: {:ok, :agy}
  defp normalize_backend(_other), do: :error
end
