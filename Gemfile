source "https://rubygems.org"

gemspec

group :development do
  # Generates and verifies the RBS signatures under sig/generated/ from
  # the inline #: annotations. Pinned exactly: signature formatting can
  # change between releases, and a different version would make
  # `sentinel check` flag the committed sigs as stale in CI.
  gem "rbs-sentinel", "0.3.4"
end
