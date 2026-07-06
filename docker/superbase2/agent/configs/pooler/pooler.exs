{:ok, _} = Application.ensure_all_started(:supavisor)

{:ok, version} =
  case Supavisor.Repo.query!("select version()") do
    %{rows: [[ver]]} -> Supavisor.Helpers.parse_pg_version(ver)
    _ -> nil
  end

# Helper: get env var with default, treating empty string as unset
env_int = fn var, default ->
  case System.get_env(var) do
    nil -> default
    "" -> default
    val -> String.to_integer(val)
  end
end

env_str = fn var, default ->
  case System.get_env(var) do
    nil -> default
    "" -> default
    val -> val
  end
end

params = %{
  "external_id" => env_str.("POOLER_TENANT_ID", "default"),
  "db_host" => "db",
  "db_port" => env_int.("POSTGRES_PORT", 5432),
  "db_database" => env_str.("POSTGRES_DB", "postgres"),
  "require_user" => false,
  "auth_query" => "SELECT * FROM pgbouncer.get_auth($1)",
  "default_max_clients" => env_int.("POOLER_MAX_CLIENT_CONN", 100),
  "default_pool_size" => env_int.("POOLER_DEFAULT_POOL_SIZE", 20),
  "default_parameter_status" => %{"server_version" => version},
  "users" => [%{
    "db_user" => "pgbouncer",
    "db_password" => System.get_env("POSTGRES_PASSWORD"),
    "mode_type" => env_str.("POOLER_POOL_MODE", "transaction"),
    "pool_size" => env_int.("POOLER_DEFAULT_POOL_SIZE", 20),
    "is_manager" => true,
    "db_user_alias" => "pgbouncer"
  }]
}

tenant = Supavisor.Tenants.get_tenant_by_external_id(params["external_id"])

if tenant do
  {:ok, _} = Supavisor.Tenants.update_tenant(tenant, params)
else
  {:ok, _} = Supavisor.Tenants.create_tenant(params)
end
