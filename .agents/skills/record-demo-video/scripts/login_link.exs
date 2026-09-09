# Prints a one-time magic login link for a dev user, so a recording can authenticate without anyone
# typing a password. Run with: mix run login_link.exs <email> <port>
[email, port] =
  case System.argv() do
    [email, port] -> [email, port]
    [email] -> [email, System.get_env("PORT", "4000")]
    _no_args -> raise "usage: mix run login_link.exs <email> [port]"
  end

Dishbooks.Users.deliver_login_or_signup_instructions(email, fn token ->
  url = "http://localhost:#{port}/login/#{token}"
  IO.puts("MAGIC_LINK #{url}")
  url
end)
