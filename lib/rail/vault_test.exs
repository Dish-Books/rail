defmodule Rail.VaultTest do
  use Rail.DataCase, async: true

  alias Rail.Vault

  test "encrypt and decrypt roundtrip" do
    plaintext = "super-secret-linear-token-12345"

    assert {:ok, ciphertext} = Vault.encrypt(plaintext)
    assert byte_size(ciphertext) > 0
    refute ciphertext == plaintext

    assert {:ok, ^plaintext} = Vault.decrypt(ciphertext)
  end

  test "encrypt! and decrypt! roundtrip" do
    plaintext = "github-app-token-67890"

    ciphertext = Vault.encrypt!(plaintext)
    assert byte_size(ciphertext) > 0
    refute ciphertext == plaintext

    assert Vault.decrypt!(ciphertext) == plaintext
  end
end
