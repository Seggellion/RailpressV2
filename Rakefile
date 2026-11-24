# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require_relative "config/application"

Rails.application.load_tasks

# Propshaft discovers files in filesystem order. Serialize the generated
# manifest consistently so independent native builds can verify the same bytes.
Rake::Task["assets:precompile"].enhance do
  path = Rails.application.config.assets.manifest_path
  manifest = JSON.parse(path.binread)
  File.atomic_write(path) { |file| file.write(JSON.generate(manifest.sort.to_h)) }
end
