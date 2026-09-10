defmodule Rail.Types.EncryptedBinaryTest do
  use Rail.DataCase, async: true

  alias Rail.Types.EncryptedBinary

  test "type returns :binary" do
    assert EncryptedBinary.type() == :binary
  end

  test "cast returns valid binary value" do
    assert {:ok, "plain text"} = EncryptedBinary.cast("plain text")
    assert {:ok, nil} = EncryptedBinary.cast(nil)
    assert :error = EncryptedBinary.cast(123)
  end

  test "dump and load encrypts and decrypts" do
    plaintext = "my-secret-key"

    assert {:ok, ciphertext} = EncryptedBinary.dump(plaintext)
    assert byte_size(ciphertext) > 0
    refute ciphertext == plaintext

    assert {:ok, ^plaintext} = EncryptedBinary.load(ciphertext)
    assert {:ok, nil} = EncryptedBinary.dump(nil)
    assert {:ok, nil} = EncryptedBinary.load(nil)
  end
end
