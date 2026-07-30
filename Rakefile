require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

namespace :site do
  desc "Collect the repo's markdown into site/content/ for Zola"
  task :collect do
    ruby File.join(__dir__, "site", "collect.rb")
  end

  desc "Collect, then build the docs site into site/public"
  task build: :collect do
    Dir.chdir(File.join(__dir__, "site")) { sh "zola build" }
  end

  desc "Collect, then serve the docs site with live reload"
  task serve: :collect do
    Dir.chdir(File.join(__dir__, "site")) { sh "zola serve" }
  end
end

task default: :test
