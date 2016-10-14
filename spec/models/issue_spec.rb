# == Schema Information
#
# Table name: issues
#
#  id                       :integer          not null, primary key
#  created_by_changeset_id  :integer
#  resolved_by_changeset_id :integer
#  details                  :string
#  issue_type               :string
#  open                     :boolean          default(TRUE)
#  created_at               :datetime
#  updated_at               :datetime
#

describe Issue do

  it 'can be created' do
    changeset = create(:changeset)
    issue = Issue.new(created_by_changeset: changeset)
  end

  it 'changeset_from_entities' do

  end

  it '.with_type' do
    changeset = create(:changeset)
    Issue.new(created_by_changeset: changeset, issue_type: 'stop_position_inaccurate').save!
    Issue.new(created_by_changeset: changeset, issue_type: 'rsp_line_inaccurate').save!
    expect(Issue.with_type('stop_position_inaccurate,fake').size).to eq 1
    expect(Issue.with_type('stop_position_inaccurate,rsp_line_inaccurate').size).to eq 2
    expect(Issue.with_type('fake1,fake2').size).to eq 0
  end

  it '.from_feed having entities_with_issues' do
    feed_version1 = create(:feed_version_sfmta_6731593)
    stop1 = create(:stop)
    stop1.entities_imported_from_feed.create(feed: feed_version1.feed, feed_version: feed_version1)
    rsp1 = create(:route_stop_pattern)
    rsp1.entities_imported_from_feed.create(feed: feed_version1.feed, feed_version: feed_version1)

    feed_version2 = create(:feed_version_bart)
    stop2 = create(:stop_richmond)
    stop2.entities_imported_from_feed.create(feed: feed_version2.feed, feed_version: feed_version2)
    rsp2 = create(:route_stop_pattern_bart)
    rsp2.entities_imported_from_feed.create(feed: feed_version2.feed, feed_version: feed_version2)

    changeset1 = create(:changeset)
    changeset2 = create(:changeset)

    @test_issue = Issue.create(created_by_changeset: changeset1,
                          issue_type: 'stop_rsp_distance_gap')
    @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: stop1.id, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
    @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: rsp1.id, entity_type: 'RouteStopPattern', issue: @test_issue, entity_attribute: 'geometry')
    @other_issue = Issue.create(created_by_changeset: changeset2,
                          issue_type: 'stop_rsp_distance_gap')
    @other_issue.entities_with_issues << EntityWithIssues.new(entity_id: stop2.id, entity_type: 'Stop', issue: @other_issue, entity_attribute: 'geometry')
    @other_issue.entities_with_issues << EntityWithIssues.new(entity_id: rsp2.id, entity_type: 'RouteStopPattern', issue: @other_issue, entity_attribute: 'geometry')

    expect(Issue.from_feed('f-9q8y-sfmta').size).to eq 1
    expect(Issue.from_feed('f-9q9-bart').size).to eq 1
  end

  it '.from_feed having no entities_with_issues' do
    feed1 = create(:feed_sfmta)
    feed2 = create(:feed_bart)
    changeset1 = create(:changeset, imported_from_feed: feed1)
    changeset2 = create(:changeset, imported_from_feed: feed2)
    Issue.new(created_by_changeset: changeset1, issue_type: 'stop_position_inaccurate').save!
    Issue.new(created_by_changeset: changeset1, issue_type: 'rsp_line_inaccurate').save!
    Issue.new(created_by_changeset: changeset2, issue_type: 'rsp_line_inaccurate').save!
    expect(Issue.from_feed('f-9q8y-sfmta').size).to eq 2
    expect(Issue.from_feed('f-9q9-bart').size).to eq 1
  end

  context 'existing issues' do
    before(:each) do
      @feed, @feed_version = load_feed(feed_version_name: :feed_version_example_issues, import_level: 1)
      # Issues:
      # 1 - 6: rsp_line_inaccurate
      # 7: distance_calculation_inaccurate (s-9qkxnx40xt-furnacecreekresortdemo & r-9qsb-20-8d5767-6bb5fc)
      # 8: stop_rsp_distance_gap (s-9qscwx8n60-nyecountyairportdemo & r-9qscy-30-a41e99-fcca25)
    end

    it 'can be resolved' do
      Timecop.freeze(3.minutes.from_now) do
        changeset = create(:changeset, payload: {
          changes: [
            action: 'createUpdate',
            issuesResolved: [8],
            stop: {
              onestopId: 's-9qscwx8n60-nyecountyairportdemo',
              timezone: 'America/Los_Angeles',
              "geometry": {
                "type": "Point",
                "coordinates": [-116.784582, 36.888446]
              }
            }
          ]
        })
        expect(Sidekiq::Logging.logger).to receive(:info).with(/Calculating distances/)
        expect(Sidekiq::Logging.logger).to receive(:info).with(/Deprecating issue: \{"id"=>8.*"resolved_by_changeset_id"=>2.*"open"=>false/)
        changeset.apply!
      end
    end

    it 'does not apply changeset that does not resolve payload issues_resolved' do
      Timecop.freeze(3.minutes.from_now) do
        changeset = create(:changeset, payload: {
          changes: [
            action: 'createUpdate',
            issuesResolved: [8],
            stop: {
              onestopId: 's-9qscwx8n60-nyecountyairportdemo',
              timezone: 'America/Los_Angeles',
              "geometry": {
                "type": "Point",
                "coordinates": [-100.0, 50.0]
              }
            }
          ]
        })
        expect {
          changeset.apply!
        }.to raise_error(Changeset::Error)
      end
    end

    context 'issue deprecation' do
      it 'deprecates issues of old feed version imports with the same entities' do
        Timecop.freeze(3.minutes.from_now) do
          load_feed(feed_version: @feed_version, import_level: 1)
        end
        expect(Issue.count).to eq 8
        expect{Issue.find(1)}.to raise_error(ActiveRecord::RecordNotFound)
        expect(Issue.find(9).created_by_changeset_id).to eq 2
      end

      it 'deprecates issues created by older changesets of associated entities' do
        changeset = nil
        Timecop.freeze(3.minutes.from_now) do
          # NOTE: although this changeset would resolve an issue,
          # we are explicitly avoiding that just to test deprecation. Furthermore, this changeset
          # creates a similar issue (but involving a different rsp) to the
          # one being deprecated.
          changeset = create(:changeset, payload: {
            changes: [
              action: 'createUpdate',
              stop: {
                onestopId: 's-9qscwx8n60-nyecountyairportdemo',
                timezone: 'America/Los_Angeles',
                "geometry": {
                  "type": "Point",
                  "coordinates": [-116.784582, 36.888446]
                }
              }
            ]
          })
          expect(Sidekiq::Logging.logger).to receive(:info).with(/Calculating distances/)
          # making sure open=true because we are not resolving the issue here
          expect(Sidekiq::Logging.logger).to receive(:info).with(/Deprecating issue: \{"id"=>8.*"open"=>true/)
          changeset.apply!
        end
        expect{Issue.find(8)}.to raise_error(ActiveRecord::RecordNotFound)
        # similar to issue 8, but involves a different rsp
        expect(Issue.find(9).created_by_changeset_id).to eq changeset.id
      end

      it 'ignores FeedVersion issues during deprecation' do
        # duplicate the entire feed import, which should deprecate all previous imports' issues
        # except the the FeedVersion issue
        issue = Issue.create!(issue_type: 'feed_version_maintenance_extend', details: 'extend this feed')
        issue.entities_with_issues.create!(entity: FeedVersion.first)
        Timecop.freeze(3.minutes.from_now) do
          load_feed(feed_version: @feed_version, import_level: 1)
        end
        expect(Issue.find(issue.id).issue_type).to eq 'feed_version_maintenance_extend'
      end

      context 'entity attributes' do
        before(:each) do
          @rsp = RouteStopPattern.find_by_onestop_id!('r-9qsb-20-8d5767-6bb5fc')
        end

        it '.issues_of_entity' do
          issue = Issue.create!(issue_type: 'rsp_line_inaccurate', details: 'this is a fake geometry issue')
          issue.entities_with_issues.create!(entity: @rsp, entity_attribute: 'geometry')
          expect(Issue.issues_of_entity(@rsp, entity_attributes: ["stop_distances"])).to match_array([Issue.find(7)])
          expect(Issue.issues_of_entity(@rsp, entity_attributes: [])).to match_array([issue, Issue.find(7)])
        end

        it 'only deprecates issues of specified entity attributes' do
          issue = Issue.create!(issue_type: 'rsp_line_inaccurate', details: 'this is a fake geometry issue')
          issue.entities_with_issues.create!(entity: @rsp, entity_attribute: 'geometry')
          # here we are modifying this rsp's geometry, which should deprecate the rsp_line_inaccurate issue
          # even without technically resolving it, because the entity attribute geometry has been modified.
          # other issues on the rsp involving other attributes should be left alone.
          changeset = create(:changeset, payload: {
            changes: [
              action: 'createUpdate',
              routeStopPattern: {
                onestopId: @rsp.onestop_id,
                "geometry": {
                  "type": "LineString",
                  "coordinates": [[-117.13316, 36.42529], [-117.05, 36.65], [-116.81797, 36.88108]]
                }
              }
            ]
          })
          expect(Sidekiq::Logging.logger).to receive(:info).with(/Calculating distances/)
          expect(Sidekiq::Logging.logger).to receive(:info).with(/Deprecating issue: \{"id"=>9.*"resolved_by_changeset_id"=>nil.*"open"=>true/)
          changeset.apply!
          expect(Issue.find(7).issue_type).to eq 'distance_calculation_inaccurate'
          expect(Issue.find(7).entities_with_issues.map(&:entity)).to include(@rsp)
        end
      end
    end

    it 'destroys entities_with_issues when issue destroyed' do
      Issue.find(8).destroy
      expect{Issue.find(8)}.to raise_error(ActiveRecord::RecordNotFound)
      expect{EntityWithIssues.find(10)}.to raise_error(ActiveRecord::RecordNotFound)
      expect{EntityWithIssues.find(11)}.to raise_error(ActiveRecord::RecordNotFound)
    end

    context 'equivalency' do
      before(:each) do
        @test_issue = Issue.new(created_by_changeset: @feed_version.changesets_imported_from_this_feed_version.first,
                              issue_type: 'stop_rsp_distance_gap')
      end

      it 'determines equivalent?' do
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 1, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 3, entity_type: 'RouteStopPattern', issue: @test_issue, entity_attribute: 'geometry')
        expect(Issue.last.equivalent?(@test_issue)).to be true
      end

      it 'determines not equivalent?' do
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 1, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
        expect(Issue.last.equivalent?(@test_issue)).to be false
      end

      it 'finds equivalent issue when entities with issues are matching' do
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 1, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 3, entity_type: 'RouteStopPattern', issue: @test_issue, entity_attribute: 'geometry')
        expect(Issue.find_by_equivalent(@test_issue)).to eq Issue.last
      end

      it 'returns nil when entities with issues are not matching exactly' do
        @test_issue.entities_with_issues << EntityWithIssues.new(entity_id: 1, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
        expect(Issue.find_by_equivalent(@test_issue)).to be nil
      end

      it 'returns nil when Issue attributes are not matching' do
        other_issue = Issue.new(created_by_changeset: @feed_version.changesets_imported_from_this_feed_version.first,
                              issue_type: 'stop_position_inaccurate')
        other_issue.entities_with_issues << EntityWithIssues.new(entity_id: 1, entity_type: 'Stop', issue: @test_issue, entity_attribute: 'geometry')
        expect(Issue.find_by_equivalent(other_issue)).to be nil
      end
    end
  end
end
