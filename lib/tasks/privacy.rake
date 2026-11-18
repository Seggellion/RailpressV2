namespace :privacy do
  desc "Inspect fixed public HTTP responses in-process; not browser/host/legal attestation"
  task inspect: :environment do
    site = Site.find_by!(singleton_key: 1)
    report = Privacy::Diagnostics.call(site)
    Privacy::Diagnostics.write!(report)
    puts JSON.pretty_generate(report)
    abort "Public response checks require attention; inspect the recorded snapshot" unless report["checks_pass"]
  end
end
