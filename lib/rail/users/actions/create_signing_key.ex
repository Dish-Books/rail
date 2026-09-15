defmodule Rail.Users.Actions.CreateSigningKey do
  @moduledoc """
  Gives the scope's user a key Rail signs their commits with.

  The pair is generated in-process and the public half registered on GitHub, so
  setting up signing is one click rather than a shell session and a settings
  page. The private half is Rail's to hold because Rail is what commits: an
  engineer run's commit is authored by whoever the ticket is assigned to, and
  GitHub will only call it verified if the signature is theirs.

  Generating replaces whatever was there, old GitHub key first, so a rekey never
  leaves a dead key on the account.
  """

  alias Rail.GitHub.Client, as: GitHub
  alias Rail.Repo
  alias Rail.Scope
  alias Rail.Users
  alias Rail.Users.Schemas.User

  @doc """
  Generates a signing key for the scope's user and registers it with GitHub.
  """
  def create_signing_key(%Scope{user: %User{github_token: token} = user} = scope) when is_binary(token) do
    with :ok <- Users.delete_signing_key(scope),
         {:ok, private, public} <- generate(user),
         {:ok, key_id} <- GitHub.create_signing_key(token, "Rail (#{user.login})", public) do
      user
      |> Repo.reload!()
      |> User.changeset(%{signing_key: private, signing_public_key: public, signing_key_github_id: key_id})
      |> Repo.update()
    end
  end

  def create_signing_key(%Scope{user: %User{}}), do: {:error, :no_github_token}
  def create_signing_key(_scope), do: {:error, :not_authenticated}

  # OTP's ssh_file encodes ed25519 as an ECPrivateKey on the Ed25519 curve. Its
  # private field is written as given, and OpenSSH expects the seed followed by
  # the public key there, so both go in.
  @ed25519 {:namedCurve, {1, 3, 101, 112}}

  defp generate(%User{} = user) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    private_key = {:ECPrivateKey, 1, private <> public, @ed25519, public, :asn1_NOVALUE}

    {:ok, :ssh_file.encode([{[{private_key, user.email}], []}], :openssh_key_v1),
     String.trim(:ssh_file.encode([{{{:ECPoint, public}, @ed25519}, [comment: user.email]}], :openssh_key))}
  end
end
