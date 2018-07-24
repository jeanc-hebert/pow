defmodule Pow.Phoenix do
  @moduledoc """
  A module that provides authentication system for your  Phoenix app.

  ## Usage

  Create `lib/my_project_web/pow.ex`:

      defmodule MyAppWeb.Pow do
        use Pow, :web,
          user: MyApp.Users.User,
          repo: MyApp.Repo,
          extensions: [PowExtensionOne, PowExtensionTwo]
      end

  The following modules will be made available:

    - `MyAppWeb.Pow.Phoenix.Router`
    - `MyAppWeb.Pow.Phoenix.Messages`
    - `MyAppWeb.Pow.Plug.Session`

  For extensions integration, `Pow.Extension.Phoenix.ControllerCallbacks`
  will also be automatically included in the `:web` configuration
  unless `:controller_callbacks_backend` has already been set.
  """
  alias Pow.Extension.Phoenix.ControllerCallbacks

  defmacro __using__(config) do
    quote do
      config = unquote(__MODULE__).__parse_config__(unquote(config))

      unquote(__MODULE__).__create_phoenix_router_mod__(__MODULE__, config)
      unquote(__MODULE__).__create_phoenix_messages_mod__(__MODULE__, config)
      unquote(__MODULE__).__create_plug_session_mod__(__MODULE__, config)
    end
  end

  def __parse_config__(config) do
    Keyword.put_new(config, :controller_callbacks, ControllerCallbacks)
  end

  defmacro __create_phoenix_router_mod__(mod, config) do
    quote do
      config = unquote(config)
      name   = unquote(mod).Phoenix.Router
      quoted = quote do
        config = unquote(config)

        defmacro __using__(_opts) do
          name   = unquote(name)
          config = unquote(config)
          quote do
            require Pow.Phoenix.Router
            use Pow.Extension.Phoenix.Router, unquote(config)
            import unquote(name)
          end
        end

        defmacro pow_routes do
          quote do
            Pow.Phoenix.Router.pow_routes()
            pow_extension_routes()
          end
        end
      end

      Module.create(name, quoted, Macro.Env.location(__ENV__))
    end
  end

  defmacro __create_phoenix_messages_mod__(mod, config) do
    quote do
      config = unquote(config)
      name   = unquote(mod).Phoenix.Messages
      quoted = quote do
        config = unquote(config)

        defmacro __using__(_opts) do
          config = unquote(config)
          quote do
            use Pow.Phoenix.Messages
            use Pow.Extension.Phoenix.Messages,
              unquote(config)
          end
        end
      end

      Module.create(name, quoted, Macro.Env.location(__ENV__))
    end
  end

  defmacro __create_plug_session_mod__(mod, config) do
    quote do
      name   = unquote(mod).Plug.Session
      mod    = Pow.Plug.Session
      config = unquote(config)
      quoted = quote do
        def init(_opts), do: unquote(mod).init(unquote(config))
        def call(conn, opts), do: unquote(mod).call(conn, opts)
        def fetch(conn, _opts), do: unquote(mod).fetch(conn, unquote(config))
        def create(conn, _opts), do: unquote(mod).create(conn, unquote(config))
        def delete(conn, _opts), do: unquote(mod).delete(conn, unquote(config))
      end

      Module.create(name, quoted, Macro.Env.location(__ENV__))
    end
  end
end
