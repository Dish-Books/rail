defmodule Rail.Git.Actions.CredentialEnvTest do
  use Rail.DataCase, async: true

  alias Rail.Git
  alias Rail.GitHub.Client
  alias Rail.Projects.Schemas.Project

  test "has git push with a token minted from the project's installation" do
    Req.Test.expect(Client, fn conn ->
      assert conn.request_path == "/app/installations/47031/access_tokens"
      Req.Test.json(conn, %{"token" => "ghs_installation_token"})
    end)

    assert {:ok, %{"RAIL_GIT_TOKEN" => "ghs_installation_token", "GIT_CONFIG_KEY_0" => "credential.helper"}} =
             Git.credential_env(%Project{github_installation_id: 47_031})
  end

  test "says so when GitHub will not mint one" do
    Req.Test.expect(Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
    end)

    assert {:error, {:github_api_error, 404, _body}} = Git.credential_env(%Project{github_installation_id: 47_032})
  end
end
