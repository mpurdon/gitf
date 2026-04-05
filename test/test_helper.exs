Code.require_file("test/support/mocks.ex")
Code.require_file("test/support/store_helper.ex")

# Isolate MCP socket in tests to prevent already_running collisions
System.put_env("GITF_MCP_SOCK", "/tmp/gitf_mcp_test_#{System.unique_integer([:positive])}.sock")

# Ensure homebrew git is preferred over Xcode git (which may need license acceptance)
brew_bin = "/opt/homebrew/bin"

if File.exists?(Path.join(brew_bin, "git")) do
  path = System.get_env("PATH", "")

  unless String.starts_with?(path, brew_bin) do
    System.put_env("PATH", "#{brew_bin}:#{path}")
  end
end

ExUnit.start()
