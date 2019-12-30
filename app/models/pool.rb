class Pool < ApplicationRecord
  class RevertError < Exception; end
  POOL_ORDER_LIMIT = 1000

  array_attribute :post_ids, parse: /\d+/, cast: :to_i
  belongs_to_creator

  validates_uniqueness_of :name, case_sensitive: false, if: :name_changed?
  validate :validate_name, if: :name_changed?
  validates_inclusion_of :category, :in => %w(series collection)
  validate :updater_can_remove_posts
  validate :updater_can_edit_deleted
  before_validation :normalize_post_ids
  before_validation :normalize_name
  after_save :create_version
  after_create :synchronize!

  api_attributes including: [:creator_name, :post_count]

  module SearchMethods
    def deleted
      where("pools.is_deleted = true")
    end

    def undeleted
      where("pools.is_deleted = false")
    end

    def series
      where("pools.category = ?", "series")
    end

    def collection
      where("pools.category = ?", "collection")
    end

    def series_first
      order(Arel.sql("(case pools.category when 'series' then 0 else 1 end), pools.name"))
    end

    def selected_first(current_pool_id)
      return all if current_pool_id.blank?
      reorder(Arel.sql("(case pools.id when #{current_pool_id.to_i} then 0 else 1 end), pools.name"))
    end

    def name_matches(name)
      name = normalize_name_for_search(name)
      name = "*#{name}*" unless name =~ /\*/
      where_ilike(:name, name)
    end

    def post_tags_match(query)
      posts = Post.tag_match(query).select(:id).reorder(nil)
      joins("CROSS JOIN unnest(post_ids) AS post_id").group(:id).where("post_id IN (?)", posts)
    end

    def default_order
      order(updated_at: :desc)
    end

    def search(params)
      q = super

      q = q.search_attributes(params, :creator, :is_active, :is_deleted, :name, :description, :post_ids)
      q = q.text_attribute_matches(:description, params[:description_matches])

      if params[:post_tags_match]
        q = q.post_tags_match(params[:post_tags_match])
      end

      if params[:name_matches].present?
        q = q.name_matches(params[:name_matches])
      end

      if params[:category] == "series"
        q = q.series
      elsif params[:category] == "collection"
        q = q.collection
      end

      params[:order] ||= params.delete(:sort)
      case params[:order]
      when "name"
        q = q.order("pools.name")
      when "created_at"
        q = q.order("pools.created_at desc")
      when "post_count"
        q = q.order(Arel.sql("cardinality(post_ids) desc")).default_order
      else
        q = q.apply_default_order(params)
      end

      q
    end
  end

  extend SearchMethods

  def self.name_to_id(name)
    if name =~ /^\d+$/
      name.to_i
    else
      select_value_sql("SELECT id FROM pools WHERE lower(name) = ?", name.downcase.tr(" ", "_")).to_i
    end
  end

  def self.normalize_name(name)
    name.gsub(/[_[:space:]]+/, "_").gsub(/\A_|_\z/, "")
  end

  def self.normalize_name_for_search(name)
    normalize_name(name).mb_chars.downcase
  end

  def self.named(name)
    if name =~ /^\d+$/
      where("pools.id = ?", name.to_i)
    elsif name
      where_ilike(:name, normalize_name_for_search(name))
    else
      nil
    end
  end

  def self.find_by_name(name)
    named(name).try(:first)
  end

  def versions
    if PoolArchive.enabled?
      PoolArchive.where("pool_id = ?", id).order("id asc")
    else
      raise "Archive service not configured"
    end
  end

  def is_series?
    category == "series"
  end

  def is_collection?
    category == "collection"
  end

  def normalize_name
    self.name = Pool.normalize_name(name)
  end

  def pretty_name
    name.tr("_", " ")
  end

  def pretty_category
    category.titleize
  end

  def normalize_post_ids
    self.post_ids = post_ids.uniq if is_collection?
  end

  def revert_to!(version)
    if id != version.pool_id
      raise RevertError.new("You cannot revert to a previous version of another pool.")
    end

    self.post_ids = version.post_ids
    self.name = version.name
    self.description = version.description
    synchronize!
  end

  def contains?(post_id)
    post_ids.include?(post_id)
  end

  def page_number(post_id)
    post_ids.find_index(post_id).to_i + 1
  end

  def deletable_by?(user)
    user.is_builder?
  end

  def updater_can_edit_deleted
    if is_deleted? && !deletable_by?(CurrentUser.user)
      errors[:base] << "You cannot update pools that are deleted"
    end
  end

  def create_mod_action_for_delete
    ModAction.log("deleted pool ##{id} (name: #{name})", :pool_delete)
  end

  def create_mod_action_for_undelete
    ModAction.log("undeleted pool ##{id} (name: #{name})", :pool_undelete)
  end

  def add!(post)
    return if contains?(post.id)
    return if is_deleted?

    with_lock do
      update(post_ids: post_ids + [post.id])
      post.add_pool!(self, true)
    end
  end

  def remove!(post)
    return unless contains?(post.id)
    return unless CurrentUser.user.can_remove_from_pools?

    with_lock do
      reload
      update(post_ids: post_ids - [post.id])
      post.remove_pool!(self)
    end
  end

  # XXX unify with PostQueryBuilder ordpool search
  def posts
    pool_posts = Pool.where(id: id).joins("CROSS JOIN unnest(pools.post_ids) WITH ORDINALITY AS row(post_id, pool_index)").select(:post_id, :pool_index)
    posts = Post.joins("JOIN (#{pool_posts.to_sql}) pool_posts ON pool_posts.post_id = posts.id").order("pool_posts.pool_index ASC")
  end

  def synchronize
    post_ids_before = post_ids_before_last_save || post_ids_was
    added = post_ids - post_ids_before
    removed = post_ids_before - post_ids

    added.each do |post_id|
      post = Post.find(post_id)
      post.add_pool!(self, true)
    end

    removed.each do |post_id|
      post = Post.find(post_id)
      post.remove_pool!(self)
    end

    normalize_post_ids
  end

  def synchronize!
    synchronize
    save if will_save_change_to_post_ids?
  end

  def post_count
    post_ids.size
  end

  def first_post?(post_id)
    post_id == post_ids.first
  end

  def last_post?(post_id)
    post_id == post_ids.last
  end

  # XXX finds wrong post when the pool contains multiple copies of the same post (#2042).
  def previous_post_id(post_id)
    return nil if first_post?(post_id) || !contains?(post_id)

    n = post_ids.index(post_id) - 1
    post_ids[n]
  end

  def next_post_id(post_id)
    return nil if last_post?(post_id) || !contains?(post_id)

    n = post_ids.index(post_id) + 1
    post_ids[n]
  end

  def cover_post_id
    post_ids.first
  end

  def create_version(updater: CurrentUser.user, updater_ip_addr: CurrentUser.ip_addr)
    if PoolArchive.enabled?
      PoolArchive.queue(self, updater, updater_ip_addr)
    else
      Rails.logger.warn("Archive service is not configured. Pool versions will not be saved.")
    end
  end

  def last_page
    (post_count / CurrentUser.user.per_page.to_f).ceil
  end

  def creator_name
    creator.name
  end

  def validate_name
    case name
    when /\A(any|none|series|collection)\z/i
      errors[:name] << "cannot be any of the following names: any, none, series, collection"
    when /,/
      errors[:name] << "cannot contain commas"
    when /\*/
      errors[:name] << "cannot contain asterisks"
    when /\A_/
      errors[:name] << "cannot begin with an underscore"
    when /_\z/
      errors[:name] << "cannot end with an underscore"
    when /__/
      errors[:name] << "cannot contain consecutive underscores"
    when /[^[:graph:]]/
      errors[:name] << "cannot contain non-printable characters"
    when ""
      errors[:name] << "cannot be blank"
    when /\A[0-9]+\z/
      errors[:name] << "cannot contain only digits"
    end
  end

  def updater_can_remove_posts
    removed = post_ids_was - post_ids
    if removed.any? && !CurrentUser.user.can_remove_from_pools?
      errors[:base] << "You cannot removes posts from pools within the first week of sign up"
    end
  end
end
