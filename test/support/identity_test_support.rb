require "tmpdir"
require "fileutils"
require_relative "qualification_evidence"

module IdentityTestSupport
  extend ActiveSupport::Concern
  PASSWORD = "synthetic-owner-phrase-2026!".freeze

  included do
    self.use_transactional_tests = false
    setup do
      @previous_private_root = ENV["RAILPRESS_PRIVATE_STATE_ROOT"]
      @previous_mail_enabled = ENV["RAILPRESS_TEST_MAIL_DELIVERY"]
      base = Rails.root.join(".local/state/m02-tests", ENV.fetch("RAILPRESS_TEST_ENGINE"))
      FileUtils.mkdir_p(base)
      @private_root = Dir.mktmpdir("identity-", base)
      ENV["RAILPRESS_PRIVATE_STATE_ROOT"] = @private_root
      ENV.delete("RAILPRESS_TEST_MAIL_DELIVERY")
      @state = Railpress::BootstrapState.for_application
      reset_identity_data
      Current.reset
      https! if respond_to?(:https!)
    end
    teardown do
      retained = !passed?
      begin
        QualificationEvidence.retain!(@private_root, test: name, classes: failures.map { |failure| (failure.respond_to?(:error) ? failure.error : failure).class.name }) if retained && @private_root
        capture_qualification_trace! if respond_to?(:capture_qualification_trace!)
        reset_identity_data
        Current.reset
      ensure
        retained ||= !$!.nil?
        ENV["RAILPRESS_PRIVATE_STATE_ROOT"] = @previous_private_root
        ENV["RAILPRESS_TEST_MAIL_DELIVERY"] = @previous_mail_enabled
        if @private_root && File.directory?(@private_root)
          if retained
            QualificationEvidence.retain!(@private_root, test: name, classes: failures.map { |failure| (failure.respond_to?(:error) ? failure.error : failure).class.name })
            puts "QUALIFICATION_FAILURE_CONTEXT: private identity fixture retained; no credential payload emitted"
          else
            QualificationEvidence.remove!(@private_root)
          end
        end
      end
    end
  end

  def reset_identity_data
    TestSchemaIntegrity.guard!
    config = Railpress::TestDatabase.load!(root: Rails.root, engine: ENV.fetch("RAILPRESS_TEST_ENGINE"))
    Railpress::TestDatabase.verify!(config)
    if ImportBatch.table_exists?
      SolidQueue::Job.where(class_name: %w[PortabilityExportJob PortabilityImportJob]).delete_all
      PortabilityState.delete_all
      ImportEvent.delete_all
      ImportItem.delete_all
      ImportBatch.delete_all
      PortabilityExport.delete_all
      PortabilityIdentity.delete_all
    end
    SolidQueue::Job.where(class_name: %w[OfficialNewsRefreshJob OfficialNewsSweepJob]).delete_all
    # Finished R8 observation jobs carry no arguments/credentials. Failed native
    # contexts are retained separately before this ordinary fixture cleanup.
    SolidQueue::Job.where(class_name: "StorageConfigurationJob").where.not(finished_at: nil).each(&:destroy!)
    DashboardDraftSubmission.delete_all
    OfficialNewsReview.delete_all
    OfficialNewsState.delete_all
    ReleaseRequest.delete_all
    ReadinessRun.delete_all
    if Member.table_exists?
      MemberOauthAttempt.delete_all
      MemberChallenge.delete_all
      MemberSession.delete_all
      MemberIdentity.delete_all
      Member.delete_all
      MemberThrottle.delete_all
    end
    Site.update_all(homepage_content_id: nil)
    media_blobs = MediaAsset.pluck(:blob_id, :thumbnail_blob_id).flatten.compact
    Seo::DiagnosticTarget.delete_all
    Seo::DiagnosticRun.delete_all
    Redirect.delete_all
    MediaReference.delete_all
    NavigationPreview.delete_all
    MenuLocation.delete_all
    Menu.update_all(published_revision_id: nil)
    Menu.find_each { |menu| Navigation::Tree.ordered(menu.tree).reverse_each { |row| MenuItem.where(menu_id: menu.id, key: row["key"]).delete_all } }
    MenuRevision.delete_all
    Menu.delete_all
    NavigationState.delete_all
    ThemePreview.delete_all
    ThemeState.delete_all
    ThemeOverlay.delete_all
    SolidQueue::Job.where(class_name: "ValidateThemeUploadJob").delete_all
    ThemeUpload.delete_all
    ThemeInstallation.delete_all
    ContentPreview.delete_all
    ContentRevision.delete_all
    ContentTerm.delete_all
    Content.delete_all
    MediaAsset.delete_all
    MediaUpload.delete_all
    ActiveStorage::Blob.where(id: media_blobs).find_each do |blob|
      MediaLibrary::Storage.retained?(blob.service) ? blob.destroy! : blob.purge
    end
    Term.delete_all
    Taxonomy.delete_all
    Site.delete_all
    UserSession.delete_all
    PasswordReset.delete_all
    User.delete_all
    AuthenticationThrottle.delete_all
    PlatformState.where(scope_name: "media_configuration").delete_all
    PlatformState.where(scope_name: "release_updates").delete_all
    ActionMailer::Base.deliveries.clear
  end

  def site_attributes
    { title: "Synthetic Railpress", tagline: "Owned locally", canonical_origin: "https://publishing.example.invalid",
      locale: "en", timezone: "America/Vancouver", home_mode: "static", indexing_enabled: false }
  end

  def owner_attributes(username = "owner")
    { username: username, email: "#{username}@example.invalid", password: PASSWORD, password_confirmation: PASSWORD }
  end

  def install_site!
    token = @state.issue!
    claim = @state.claim!(token)
    Setup::Complete.call(state: @state, claim: claim, site_attributes: site_attributes, owner_attributes: owner_attributes)
    @owner = User.find_by!(role: "owner")
  end

  def create_account(role, name = role)
    Identity::ManageUsers.create!(actor: @owner, attributes: owner_attributes(name).merge(role: role))
  end

  def csrf_token_for(client, path)
    client.get(path)
    document = Nokogiri::HTML(client.response.body)
    node = document.at_css('meta[name="csrf-token"]')
    raise "CSRF form missing at #{path}: #{client.response.status}" unless node
    node["content"]
  end

  def sign_in(client = self, user = @owner, password: PASSWORD)
    token = csrf_token_for(client, "/login")
    client.post("/login", params: { identifier: user.username, password: password, authenticity_token: token })
    client.response
  end

  def create_recovery_token(user = @owner)
    ENV["RAILPRESS_TEST_MAIL_DELIVERY"] = "1"
    Identity::PasswordRecovery.deliver!("username_key", user.username_key)
    ActionMailer::Base.deliveries.last.body.decoded[/[0-9a-f]{64}/]
  end

  def parallel_results(count)
    ready = Queue.new
    start = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield index
        end
      end
    end
    count.times { ready.pop }
    count.times { start << true }
    threads.map { |thread| thread.join(20) || raise("Concurrency timeout"); thread.value }
  end
end
