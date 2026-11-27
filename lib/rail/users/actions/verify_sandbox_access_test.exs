defmodule Rail.Users.Actions.VerifySandboxAccessTest do
  use Rail.DataCase, async: true

  alias Rail.Users
  alias Rail.Users.Clients.CloudflareAccess

  setup_all do
    %{key: JOSE.JWK.generate_key({:rsa, 2048}), forger: JOSE.JWK.generate_key({:rsa, 2048})}
  end

  setup %{key: key} do
    stub(Rail, :sandbox_access, fn -> %{team_domain: "team.cloudflareaccess.com", aud: "sandbox-aud"} end)
    {_kty, public} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    Req.Test.stub(CloudflareAccess, fn %{host: "team.cloudflareaccess.com", request_path: "/cdn-cgi/access/certs"} = conn ->
      Req.Test.json(conn, %{"keys" => [public]})
    end)

    # What Access issues for a service token: no one's email, the token's client id as its name.
    claims = %{
      "email" => "",
      "common_name" => "host-ice.access",
      "iss" => "https://team.cloudflareaccess.com",
      "aud" => ["sandbox-aud"],
      "exp" => System.os_time(:second) + 300
    }

    %{
      claims: claims,
      sign: fn jwk, fields -> jwk |> JOSE.JWT.sign(%{"alg" => "RS256"}, fields) |> JOSE.JWS.compact() |> elem(1) end
    }
  end

  test "takes a host's service token for the sandbox socket's application", %{key: key, claims: claims, sign: sign} do
    assert :ok = Users.verify_sandbox_access(sign.(key, claims))
  end

  test "refuses a forged, expired, other application's or other team's token, and a string that is no token", %{
    key: key,
    forger: forger,
    claims: claims,
    sign: sign
  } do
    refused = [
      sign.(forger, claims),
      sign.(key, %{claims | "exp" => System.os_time(:second) - 1}),
      # The sign-in app's, which a person's browser carries.
      sign.(key, %{claims | "aud" => ["rail-aud"]}),
      sign.(key, %{claims | "iss" => "https://other.cloudflareaccess.com"}),
      "not-a-token"
    ]

    for token <- refused, do: assert({:error, :invalid_assertion} = Users.verify_sandbox_access(token))
  end

  test "trusts nothing while Access is not set up, and says when the team's keys cannot be read", %{
    key: key,
    claims: claims,
    sign: sign
  } do
    token = sign.(key, claims)

    Req.Test.stub(CloudflareAccess, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:access_unreachable, %Req.TransportError{reason: :econnrefused}}} =
             Users.verify_sandbox_access(token)

    stub(Rail, :sandbox_access, fn -> nil end)
    assert {:error, :access_off} = Users.verify_sandbox_access(token)
  end
end
