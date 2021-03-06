# == Schema Information
#
# Table name: feed_version_infos
#
#  id              :integer          not null, primary key
#  type            :string
#  data            :json
#  feed_version_id :integer
#  created_at      :datetime
#  updated_at      :datetime
#
# Indexes
#
#  index_feed_version_infos_on_feed_version_id           (feed_version_id)
#  index_feed_version_infos_on_feed_version_id_and_type  (feed_version_id,type) UNIQUE
#

class FeedVersionInfo < ActiveRecord::Base
  belongs_to :feed_version
  validates :feed_version_id, uniqueness: { scope: :type }, presence: true

  scope :where_feed, -> (feeds) {
    joins(:feed_version).where(feed_version: {feed_id: Array.wrap(feeds).map(&:id)})
  }

  scope :where_type, -> (t) {
    where(type: Array.wrap(t))
  }
end

class FeedVersionInfoStatistics < FeedVersionInfo
end

class FeedVersionInfoConveyalValidation < FeedVersionInfo
end

FeedVersionInfo.connection
