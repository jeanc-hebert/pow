defmodule Pow.Ecto.Schema.Changeset do
  @moduledoc """
  Handles changesets functions for Pow schema.

  These functions should never be called directly, but instead the functions
  build in macros in `Pow.Ecto.Schema` should be used. This is to ensure
  that only compile time configuration is used.

  `Pow.Ecto.Schema.Password` is by default used to hash and verify passwords.

  ## Configuration options

    * `:password_min_length`   - minimum password length, defaults to 8
    * `:password_max_length`   - maximum password length, defaults to 4096
    * `:password_hash_methods` - the password hash and verify functions to use,
      defaults to:

          {&Pow.Ecto.Schema.Password.pbkdf2_hash/1,
          &Pow.Ecto.Schema.Password.pbkdf2_verify/2}
    * `:email_validator`       - the email validation function, defaults to:


          &Pow.Ecto.Schema.Changeset.validate_email/1

        The function should either return `:ok`, `:error`, or
        `{:error, reason}`.
  """
  alias Ecto.Changeset
  alias Pow.{Config, Ecto.Schema, Ecto.Schema.Password}

  @password_min_length 8
  @password_max_length 4096

  @doc """
  Validates the user id field.

  The user id field is always required. It will be treated as case insensitive,
  and it's required to be unique. If the user id field is `:email`, the value
  will be validated as an e-mail address too.
  """
  @spec user_id_field_changeset(Ecto.Schema.t() | Changeset.t(), map(), Config.t()) :: Changeset.t()
  def user_id_field_changeset(user_or_changeset, params, config) do
    user_id_field =
      case user_or_changeset do
        %Changeset{data: %struct{}} -> struct.pow_user_id_field()
        %struct{}                   -> struct.pow_user_id_field()
      end

    user_or_changeset
    |> Changeset.cast(params, [user_id_field])
    |> Changeset.update_change(user_id_field, &maybe_normalize_user_id_field_value/1)
    |> maybe_validate_email_format(user_id_field, config)
    |> Changeset.validate_required([user_id_field])
    |> Changeset.unique_constraint(user_id_field)
  end

  defp maybe_normalize_user_id_field_value(value) when is_binary(value), do: Schema.normalize_user_id_field_value(value)
  defp maybe_normalize_user_id_field_value(any), do: any

  @doc """
  Validates the password field.

  Calls `confirm_password_changeset/3` and `new_password_changeset/3`.
  """
  @spec password_changeset(Ecto.Schema.t() | Changeset.t(), map(), Config.t()) :: Changeset.t()
  def password_changeset(user_or_changeset, params, config) do
    user_or_changeset
    |> confirm_password_changeset(params, config)
    |> new_password_changeset(params, config)
  end

  @doc """
  Validates the password field.

  A password hash is generated by using `:password_hash_methods` in the
  configuration. The password is always required if the password hash is `nil`,
  and it's required to be between `:password_min_length` to
  `:password_max_length` characters long.

  The password hash is only generated if the changeset is valid, but always
  required.
  """
  @spec new_password_changeset(Ecto.Schema.t() | Changeset.t(), map(), Config.t()) :: Changeset.t()
  def new_password_changeset(user_or_changeset, params, config) do
    user_or_changeset
    |> Changeset.cast(params, [:password])
    |> maybe_require_password()
    |> maybe_validate_password(config)
    |> maybe_put_password_hash(config)
    |> maybe_validate_password_hash()
    |> Changeset.prepare_changes(&Changeset.delete_change(&1, :password))
  end

  # TODO: Remove `confirm_password` support by 1.1.0
  @doc """
  Validates the confirm password field.

  Requires `password` and `confirm_password` params to be equal. Validation is
  only performed if a change for `:password` exists and the change is not
  `nil`.
  """
  @spec confirm_password_changeset(Ecto.Schema.t() | Changeset.t(), map(), Config.t()) :: Changeset.t()
  def confirm_password_changeset(user_or_changeset, %{confirm_password: password_confirmation} = params, _config) do
    params =
      params
      |> Map.delete(:confirm_password)
      |> Map.put(:password_confirmation, password_confirmation)

    do_confirm_password_changeset(user_or_changeset, params)
  end
  def confirm_password_changeset(user_or_changeset, %{"confirm_password" => password_confirmation} = params, _config) do
    params =
      params
      |> Map.delete("confirm_password")
      |> Map.put("password_confirmation", password_confirmation)

    convert_confirm_password_param(user_or_changeset, params)
  end
  def confirm_password_changeset(user_or_changeset, params, _config),
    do: do_confirm_password_changeset(user_or_changeset, params)

  # TODO: Remove by 1.1.0
  defp convert_confirm_password_param(user_or_changeset, params) do
    IO.warn("warning: passing `confirm_password` value to `#{inspect unquote(__MODULE__)}.confirm_password_changeset/3` has been deprecated, please use `password_confirmation` instead")

    changeset = do_confirm_password_changeset(user_or_changeset, params)
    errors    = Enum.map(changeset.errors, fn
      {:password_confirmation, error} -> {:confirm_password, error}
      error                           -> error
    end)

    %{changeset | errors: errors}
  end

  defp do_confirm_password_changeset(user_or_changeset, params) do
    changeset = Changeset.cast(user_or_changeset, params, [:password])

    changeset
    |> Changeset.get_change(:password)
    |> case do
      nil       -> changeset
      _password -> Changeset.validate_confirmation(changeset, :password, required: true)
    end
  end

  @doc """
  Validates the current password field.

  It's only required to provide a current password if the `password_hash`
  value exists in the data struct.
  """
  @spec current_password_changeset(Ecto.Schema.t() | Changeset.t(), map(), Config.t()) :: Changeset.t()
  def current_password_changeset(user_or_changeset, params, config) do
    user_or_changeset
    |> reset_current_password_field()
    |> Changeset.cast(params, [:current_password])
    |> maybe_validate_current_password(config)
    |> Changeset.prepare_changes(&Changeset.delete_change(&1, :current_password))
  end

  defp reset_current_password_field(%{data: user} = changeset) do
    %{changeset | data: reset_current_password_field(user)}
  end
  defp reset_current_password_field(user) do
    %{user | current_password: nil}
  end

  defp maybe_validate_email_format(changeset, :email, config) do
    validator = get_email_validator(config)

    Changeset.validate_change(changeset, :email, {:email_format, validator}, fn :email, email ->
      case validator.(email) do
        :ok              -> []
        :error           -> [email: {"has invalid format", validation: :email_format}]
        {:error, reason} -> [email: {"has invalid format", validation: :email_format, reason: reason}]
      end
    end)
  end
  defp maybe_validate_email_format(changeset, _type, _config), do: changeset

  defp maybe_validate_current_password(%{data: %{password_hash: nil}} = changeset, _config),
    do: changeset
  defp maybe_validate_current_password(changeset, config) do
    changeset = Changeset.validate_required(changeset, [:current_password])

    case changeset.valid? do
      true  -> validate_current_password(changeset, config)
      false -> changeset
    end
  end

  defp validate_current_password(%{data: user, changes: %{current_password: password}} = changeset, config) do
    user
    |> verify_password(password, config)
    |> case do
      true ->
        changeset

      _ ->
        changeset = %{changeset | validations: [{:current_password, {:verify_password, []}} | changeset.validations]}

        Changeset.add_error(changeset, :current_password, "is invalid", validation: :verify_password)
    end
  end

  @doc """
  Verifies a password in a struct.

  The password will be verified by using the `:password_hash_methods` in the
  configuration.

  To prevent timing attacks, a blank password will be passed to the hash method
  in the `:password_hash_methods` configuration option if the `:password_hash`
  is `nil`.
  """
  @spec verify_password(Ecto.Schema.t(), binary(), Config.t()) :: boolean()
  def verify_password(%{password_hash: nil}, _password, config) do
    config
    |> get_password_hash_function()
    |> apply([""])

    false
  end
  def verify_password(%{password_hash: password_hash}, password, config) do
    config
    |> get_password_verify_function()
    |> apply([password, password_hash])
  end

  defp maybe_require_password(%{data: %{password_hash: nil}} = changeset) do
    Changeset.validate_required(changeset, [:password])
  end
  defp maybe_require_password(changeset), do: changeset

  defp maybe_validate_password(changeset, config) do
    changeset
    |> Changeset.get_change(:password)
    |> case do
      nil -> changeset
      _   -> validate_password(changeset, config)
    end
  end

  defp validate_password(changeset, config) do
    password_min_length = Config.get(config, :password_min_length, @password_min_length)
    password_max_length = Config.get(config, :password_max_length, @password_max_length)

    Changeset.validate_length(changeset, :password, min: password_min_length, max: password_max_length)
  end

  defp maybe_put_password_hash(%Changeset{valid?: true, changes: %{password: password}} = changeset, config) do
    Changeset.put_change(changeset, :password_hash, hash_password(password, config))
  end
  defp maybe_put_password_hash(changeset, _config), do: changeset

  defp maybe_validate_password_hash(%Changeset{valid?: true} = changeset) do
    Changeset.validate_required(changeset, [:password_hash])
  end
  defp maybe_validate_password_hash(changeset), do: changeset

  defp hash_password(password, config) do
    config
    |> get_password_hash_function()
    |> apply([password])
  end

  defp get_password_hash_function(config) do
    {password_hash_function, _} = get_password_hash_functions(config)

    password_hash_function
  end

  defp get_password_verify_function(config) do
    {_, password_verify_function} = get_password_hash_functions(config)

    password_verify_function
  end

  defp get_password_hash_functions(config) do
    Config.get(config, :password_hash_methods, {&Password.pbkdf2_hash/1, &Password.pbkdf2_verify/2})
  end

  defp get_email_validator(config) do
    Config.get(config, :email_validator, &__MODULE__.validate_email/1)
  end

  @doc """
  Validates an e-mail.

  This implementation has the following rules:

  - Split into local-part and domain at last `@` occurance
  - Local-part should;
    - be at most 64 octets
    - separate quoted and unquoted content with a single dot
    - only have letters, digits, and the following characters outside quoted
      content:
  ```text
  !#$%&'*+-/=?^_`{|}~.
  ```
    - not have any consecutive dots outside quoted content
  - Domain should;
    - be at most 255 octets
    - only have letters, digits, hyphen, and dots

  Unicode characters are permitted in both local-part and domain.

  The implementation is based on
  [RFC 3696](https://tools.ietf.org/html/rfc3696#section-3).

  IP addresses are not allowed as per the RFC 3696 specification: "The domain
  name can also be replaced by an IP address in square brackets, but that form
  is strongly discouraged except for testing and troubleshooting purposes.".
  """
  @spec validate_email(binary()) :: :ok | {:error, any()}
  def validate_email(email) do
    [domain | local_parts] =
      email
      |> String.split("@")
      |> Enum.reverse()

    local_part =
      local_parts
      |> Enum.reverse()
      |> Enum.join("@")

    cond do
      String.length(local_part) > 64      -> {:error, "local-part too long"}
      String.length(domain) > 255         -> {:error, "domain too long"}
      local_part == ""                    -> {:error, "invalid format"}
      local_part_only_quoted?(local_part) -> validate_domain(domain)
      true                                -> validate_email(local_part, domain)
    end
  end

  defp validate_email(local_part, domain) do
    sanitized_local_part =
      local_part
      |> remove_comments()
      |> remove_quotes_from_local_part()

    cond do
      local_part_consective_dots?(sanitized_local_part) ->
        {:error, "consective dots in local-part"}

      local_part_valid_characters?(sanitized_local_part) ->
        validate_domain(domain)

      true ->
        {:error, "invalid characters in local-part"}
    end
  end

  defp local_part_only_quoted?(local_part),
    do: local_part =~ ~r/^"[^\"]+"$/

  defp remove_quotes_from_local_part(local_part),
    do: Regex.replace(~r/(^\".*\"$)|(^\".*\"\.)|(\.\".*\"$)?/, local_part, "")

  defp remove_comments(any),
    do: Regex.replace(~r/(^\(.*\))|(\(.*\)$)?/, any, "")

  defp local_part_consective_dots?(local_part),
    do: local_part =~ ~r/\.\./

  defp local_part_valid_characters?(sanitized_local_part),
    do: sanitized_local_part =~ ~r<^[\p{L}\p{M}0-9!#$%&'*+-/=?^_`{|}~\.]+$>u

  defp validate_domain(domain) do
    labels =
      domain
      |> remove_comments()
      |> String.split(".")

    labels
    |> validate_tld()
    |> validate_dns_labels()
  end

  defp validate_tld(labels) do
    labels
    |> List.last()
    |> Kernel.=~(~r/^[0-9]+$/)
    |> case do
      true  -> {:error, "tld cannot be all-numeric"}
      false -> {:ok, labels}
    end
  end

  defp validate_dns_labels({:ok, labels}) do
    Enum.reduce_while(labels, :ok, fn
      label, :ok    -> {:cont, validate_dns_label(label)}
      _label, error -> {:halt, error}
    end)
  end
  defp validate_dns_labels({:error, error}), do: {:error, error}

  defp validate_dns_label(label) do
    cond do
      label == ""                        -> {:error, "dns label is too short"}
      String.length(label) > 63          -> {:error, "dns label too long"}
      String.first(label) == "-"         -> {:error, "dns label begins with hyphen"}
      String.last(label) == "-"          -> {:error, "dns label ends with hyphen"}
      dns_label_valid_characters?(label) -> :ok
      true                               -> {:error, "invalid characters in dns label"}
    end
  end

  defp dns_label_valid_characters?(label),
    do: label =~ ~r/^[\p{L}\p{M}0-9-]+$/u
end
