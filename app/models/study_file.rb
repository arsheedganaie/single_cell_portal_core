class StudyFile

  ###
  #
  # StudyFile: class holding metadata about data files either uploaded through the UI or 'synced' from a GCS bucket
  #
  ###

  ###
  #
  # SETTINGS & FIELD DEFINITIONS
  #
  ###

  include Mongoid::Document
  include Mongoid::Timestamps
  include Mongoid::Paperclip
  include Rails.application.routes.url_helpers # for accessing download_file_path and download_private_file_path

  # constants, used for statuses and file types
  STUDY_FILE_TYPES = ['Cluster', 'Coordinate Labels' ,'Expression Matrix', 'MM Coordinate Matrix', '10X Genes File',
                      '10X Barcodes File', 'Gene List', 'Metadata', 'Fastq', 'BAM', 'BAM Index', 'Documentation',
                      'Other', 'Analysis Output']
  PARSEABLE_TYPES = ['Cluster', 'Coordinate Labels', 'Expression Matrix', 'MM Coordinate Matrix', '10X Genes File',
                     '10X Barcodes File', 'Gene List', 'Metadata']
  UPLOAD_STATUSES = %w(new uploading uploaded)
  PARSE_STATUSES = %w(unparsed parsing parsed)
  PRIMARY_DATA_EXTENTIONS = %w(fastq fastq.zip fastq.gz fastq.tar.gz fq fq.zip fq.gz fq.tar.gz bam bam.gz bam.bai bam.gz.bai)
  PRIMARY_DATA_TYPES = ['Fastq', 'BAM', 'BAM Index']
  GZIP_MAGIC_NUMBER = "\x1f\x8b".force_encoding(Encoding::ASCII_8BIT)

  # associations
  belongs_to :study, index: true
  has_many :cluster_groups, dependent: :destroy
  has_many :genes, dependent: :destroy
  has_many :precomputed_scores, dependent: :destroy
  has_many :cell_metadata, dependent: :destroy

  # field definitions
  field :name, type: String
  field :path, type: String
  field :description, type: String
  field :file_type, type: String
  field :status, type: String
  field :parse_status, type: String, default: 'unparsed'
  field :data_dir, type: String
  field :human_fastq_url, type: String
  field :human_data, type: Boolean, default: false
  field :generation, type: String
  field :x_axis_label, type: String, default: ''
  field :y_axis_label, type: String, default: ''
  field :z_axis_label, type: String, default: ''
  field :x_axis_min, type: Integer
  field :x_axis_max, type: Integer
  field :y_axis_min, type: Integer
  field :y_axis_max, type: Integer
  field :z_axis_min, type: Integer
  field :z_axis_max, type: Integer
  field :queued_for_deletion, type: Boolean, default: false
  field :remote_location, type: String, default: ''
  field :options, type: Hash, default: {}

  Paperclip.interpolates :data_dir do |attachment, style|
    attachment.instance.data_dir
  end

  ###
  #
  # VALIDATIONS & CALLBACKS
  #
  ###

  # callbacks
  before_validation   :set_file_name_and_data_dir, on: :create
  before_save         :sanitize_name
  after_save          :set_cluster_group_ranges

  has_mongoid_attached_file :upload,
                            :path => ":rails_root/data/:data_dir/:id/:filename",
                            :url => ''

  # turning off validation to allow any kind of data file to be uploaded
  do_not_validate_attachment_file_type :upload

  validates_uniqueness_of :upload_file_name, scope: :study_id, unless: Proc.new {|f| f.human_data?}
  validates_presence_of :name
  validates_presence_of :human_fastq_url, if: proc {|f| f.human_data}
  validates_format_of :human_fastq_url, with: URI.regexp,
                      message: 'is not a valid URL', if: proc {|f| f.human_data}
  validate :validate_name_by_file_type

  validates_format_of :description, with: ValidationTools::NO_SCRIPT_TAGS,
                      message: ValidationTools::NO_SCRIPT_TAGS_ERROR, allow_blank: true

  validates_format_of :x_axis_label, with: ValidationTools::NO_SCRIPT_TAGS,
                      message: ValidationTools::NO_SCRIPT_TAGS_ERROR,
                      allow_blank: true
  validates_format_of :y_axis_label, with: ValidationTools::NO_SCRIPT_TAGS,
                      message: ValidationTools::NO_SCRIPT_TAGS_ERROR,
                      allow_blank: true
  validates_format_of :z_axis_label, with: ValidationTools::NO_SCRIPT_TAGS,
                      message: ValidationTools::NO_SCRIPT_TAGS_ERROR,
                      allow_blank: true

  validates_format_of :generation, with: /\A\d+\z/, if: proc {|f| f.generation.present?}

  validates_inclusion_of :file_type, in: STUDY_FILE_TYPES, unless: proc {|f| f.file_type == 'DELETE'}

  ###
  #
  # INSTANCE METHODS
  #
  ###

  # return correct path to file based on visibility & type
  def download_path
    if self.upload_file_name.nil?
      self.human_fastq_url
    else
      if self.study.public?
        download_file_path(self.study.url_safe_name, filename: self.bucket_location)
      else
        download_private_file_path(self.study.url_safe_name, filename: self.bucket_location)
      end
    end
  end

  # JSON response for jQuery uploader
  def to_jq_upload(error=nil)
    {
        '_id' => self._id,
        'name' => read_attribute(:upload_file_name),
        'size' => read_attribute(:upload_file_size),
        'url' => download_path,
        'delete_url' => delete_study_file_study_path(self.study._id, self._id),
        'delete_type' => "DELETE"
    }
  end

  def parseable?
    PARSEABLE_TYPES.include?(self.file_type)
  end

  def parsed?
    self.parse_status == 'parsed'
  end

  def parsing?
    self.parse_status == 'parsing'
  end

  # determine whether we have all necessary files to parse this file.  Mainly applies to MM Coordinate Matrices and associated 10X files
  def able_to_parse?
    if !self.parseable?
      false
    else
      case self.file_type
      when 'MM Coordinate Matrix'
        StudyFile.where(file_type: '10X Genes File', 'options.matrix_id' => self.id.to_s).exists? && StudyFile.where(file_type: '10X Barcodes File', 'options.matrix_id' => self.id.to_s).exists?
      when '10X Genes File'
        parent_matrix = self.bundle_parent
        parent_matrix.present? && StudyFile.where(file_type: '10X Barcodes File', 'options.matrix_id' => parent_matrix.id.to_s).exists?
      when '10X Barcodes File'
        parent_matrix = self.bundle_parent
        parent_matrix.present? && StudyFile.where(file_type: '10X Genes File', 'options.matrix_id' => parent_matrix.id.to_s).exists?
      else
        true # the file is parseable and a singleton
      end
    end
  end

  # file type as a css class
  def file_type_class
    self.file_type.downcase.split.join('-') + '-file'
  end

  # generate a gs-url to this study file in the study's GCS bucket
  def gs_url
    "gs://#{self.study.bucket_id}/#{self.bucket_location}"
  end

  def api_url
    api_url = Study.firecloud_client.generate_api_url(self.study.firecloud_project,
                                              self.study.firecloud_workspace,
                                              self.bucket_location)
    api_url + '?alt=media'
  end

  # convert all domain ranges from floats to integers
  def convert_all_ranges
    if self.file_type == 'Cluster'
      required_vals = 4
      domain = {
          x_axis_min: self.x_axis_min.to_i == 0 ? nil : self.x_axis_min.to_i,
          x_axis_max: self.x_axis_max.to_i == 0 ? nil : self.x_axis_max.to_i,
          y_axis_min: self.y_axis_min.to_i == 0 ? nil : self.y_axis_min.to_i,
          y_axis_max: self.y_axis_max.to_i == 0 ? nil : self.y_axis_max.to_i
      }
      empty_domain = {
          x_axis_min: nil,
          x_axis_max: nil,
          y_axis_min: nil,
          y_axis_max: nil
      }
      if self.cluster_groups.first.is_3d?
        domain[:z_axis_min] = self.z_axis_min.to_i == 0 ? nil : self.z_axis_min.to_i
        domain[:z_axis_max] = self.z_axis_max.to_i == 0 ? nil : self.z_axis_max.to_i
        empty_domain[:z_axis_min] = nil
        empty_domain[:z_axis_max] = nil
        required_vals = 6
      end
      # need to clear out domain first to force persistence
      self.update(empty_domain)
      if required_vals == domain.values.compact.size
        self.update(domain)
      end
    end
  end

  # end path for a file when localizing during a parse
  def download_location
    self.remote_location.blank? ? File.join(self.id, self.upload_file_name) : self.remote_location
  end

  # for constructing a path to a file in a Google bucket
  def bucket_location
    self.remote_location.blank? ? self.upload_file_name : self.remote_location
  end

  # get any 'bundled' files that correspond to this file
  def bundled_files
    # base 'selector' for query, used to search study_file.options hash
    selector = 'options'
    case self.file_type
    when 'MM Coordinate Matrix'
      selector += '.matrix_id'
    when 'BAM'
      selector += '.bam_id'
    when 'Cluster'
      selector += '.cluster_group_id'
    end
    StudyFile.where(selector => self.id.to_s) # return Mongoid::Criteria to lazy-load, better performance
  end

  # get the bundle 'parent' file for a bundled file (e.g. MM Coordinate Matrix that is bundled with a 10X Genes File)
  # inverse of study_file.bundled_files.  In the case of Coordinate Labels, this returns the cluster, not the file
  def bundle_parent
    model = StudyFile
    case self.file_type
    when /10X/
      selector = :matrix_id
    when 'BAM Index'
      selector = :bam_id
    when 'Coordinate Labels'
      selector = :cluster_group_id
      model = ClusterGroup
    end
    # call find_by(id: ) to avoid Mongoid::Errors::InvalidFind
    model.find_by(id: self.options[selector])
  end

  # retrieve the cluster group id from the options hash for a cluster labels file
  def coordinate_labels_font_family
    if self.options[:font_family].blank?
      'Helvetica Neue'
    else
      self.options[:font_family]
    end
  end

  # retrieve the font size from the options hash for a cluster labels file
  def coordinate_labels_font_size
    if self.options[:font_size].blank?
      10
    else
      self.options[:font_size]
    end
  end

  # retrieve the font color from the options hash for a cluster labels file
  def coordinate_labels_font_color
    if self.options[:font_color].blank?
      '#333333'
    else
      self.options[:font_color]
    end
  end

  # determine a file's content type by reading the first 2 bytes and comparing to known magic numbers
  def determine_content_type
    location = File.join(self.study.data_store_path, self.download_location)
    signature = File.open(location).read(2)
    if signature == StudyFile::GZIP_MAGIC_NUMBER
      'application/gzip'
    else
      'text/plain'
    end
  end

  ###
  #
  # CACHING METHODS
  #
  ###

  # helper method to invalidate any matching front-end caches when parsing/deleting a study_file
  def invalidate_cache_by_file_type
    cache_key = self.cache_removal_key
    unless cache_key.nil?
      # clear matching caches in background
      CacheRemovalJob.new(cache_key).delay.perform
    end
  end

  # helper method to return cache removal key based on file type (this is refactored out for use in tests)
  def cache_removal_key
    study_name = self.study.url_safe_name
    case self.file_type
      when 'Cluster'
        name_key = self.name.split.join('-')
        @cache_key = "#{study_name}.*render_cluster.*#{name_key}"
      when 'Coordinate Labels'
        name_key = self.bundle_parent.name.split.join('-')
        @cache_key = "#{study_name}.*render_cluster.*#{name_key}"
      when 'Expression Matrix'
        @cache_key = "#{study_name}.*expression"
      when 'MM Coordinate Matrix'
        @cache_key = "#{study_name}.*expression"
      when /10X.*File/
        @cache_key = "#{study_name}.*expression"
      when 'Gene List'
        name_key = self.precomputed_scores.first.name.split.join('-')
        @cache_key = "#{study_name}.*#{name_key}"
      when 'Metadata'
        # when reparsing metadata, almost all caches now become invalid so we just clear all matching the study
        @cache_key =  "#{study_name}"
      else
        @cache_key = nil
    end
    @cache_key
  end

  ###
  #
  # DELETE METHODS
  #
  ###

  # delete all queued study file objects
  def self.delete_queued_files
    study_files = self.where(queued_for_deletion: true)
    study_files.each do |file|
      Rails.logger.info "#{Time.now} deleting queued file #{file.name} in study #{file.study.name}."
      file.destroy
      Rails.logger.info "#{Time.now} #{file.name} successfully deleted."
    end
    true
  end

  # remove a local copy on the file system if a parse fails
  def remove_local_copy
    Dir.chdir(self.study.data_store_path)
    if File.exists?(self.download_location)
      File.delete(self.download_location)
      subdir = self.remote_location.blank? ? self.id : self.remote_location.split('/').first
      if Dir.exist?(subdir) && Dir.entries(subdir).delete_if {|e| e.start_with?('.')}.empty?
        Dir.rmdir(subdir)
      end
    end
  end

  ##
  #
  # MISC METHODS
  #
  ##

  def generate_expression_matrix_cells
    begin
      study = self.study
      existing_array = DataArray.where(name: "#{self.name} Cells", array_type: 'cells', linear_data_type: 'Study',
                                       linear_data_id: self.study_id).any?
      unless existing_array
        remote = Study.firecloud_client.get_workspace_file(study.firecloud_project, study.firecloud_workspace, self.bucket_location)
        if remote.present?
          study.make_data_dir
          download_location = study.data_store_path
          if self.remote_location.blank?
            download_location = File.join(study.data_store_path, self.id)
            Dir.mkdir download_location
          elsif self.remote_location.include?('/')
            subdir = self.remote_location.split('/').first
            download_location = File.join(study.data_store_path, subdir)
          end
          msg = "#{Time.now}: localizing #{self.name} in #{study.name} to #{download_location}"
          puts msg
          Rails.logger.info msg
          file_location = File.join(study.data_store_path, self.download_location)
          Study.firecloud_client.execute_gcloud_method(:download_workspace_file, study.firecloud_project, study.firecloud_workspace, self.bucket_location, download_location, verify: :none)
          content_type = self.determine_content_type
          shift_headers = true
          if content_type == 'application/gzip'
            msg = "#{Time.now}: Parsing #{self.name}:#{self.id} as application/gzip"
            puts msg
            Rails.logger.info msg
            file = Zlib::GzipReader.open(file_location)
          else
            msg = "#{Time.now}: Parsing #{self.name}:#{self.id} as text/plain"
            puts msg
            Rails.logger.info msg
            file = File.open(file_location, 'rb')
          end
          raw_cells = file.readline.rstrip.split(/[\t,]/).map(&:strip)
          cells = self.study.sanitize_input_array(raw_cells)
          if shift_headers
            cells.shift
          end
          # close file
          file.close
          # add processed cells to known cells
          cells.each_slice(DataArray::MAX_ENTRIES).with_index do |slice, index|
            msg = "#{Time.now}: Create known cells array ##{index + 1} for #{self.name}:#{self.id} in #{study.name}"
            puts msg
            Rails.logger.info msg
            known_cells = study.data_arrays.build(name: "#{self.name} Cells", cluster_name: self.name,
                                                  array_type: 'cells', array_index: index + 1, values: slice,
                                                  study_file_id: self.id, study_id: self.study_id)
            known_cells.save
          end
          msg = "#{Time.now}: removing local copy of #{download_location}"
          self.remove_local_copy
        else
          msg = "#{Time.now}: skipping #{self.name} in #{study.name}; remote file no longer exists"
          puts msg
          Rails.logger.error msg
        end
      else
        msg = "#{Time.now}: skipping #{self.name} in #{study.name}; already processed"
        puts msg
        Rails.logger.info msg
      end
    rescue => e
      msg = "#{Time.now}: error processing #{self.name} in #{self.study.name}: #{e.message}"
      puts msg
      Rails.logger.error msg
    end
  end

  private

  ###
  #
  # CUSTOM VALIDATIONS & CALLBACKS
  #
  ###

  # strip whitespace from name if the file is a cluster or gene list (will cause problems when rendering)
  def sanitize_name
    if ['Gene List', 'Cluster'].include?(self.file_type)
      self.name.strip!
    end
  end

  # set filename and construct url safe name from study
  def set_file_name_and_data_dir
    if self.upload_file_name.nil?
      self.status = 'uploaded'
      if self.name.nil?
        self.name = ''
      end
    elsif (self.name.nil? || self.name.blank?) || (!self.new_record? && self.upload_file_name != self.name)
      self.name = self.upload_file_name
    end
    self.data_dir = self.study.data_dir
  end

  # set ranges for cluster_groups if necessary
  def set_cluster_group_ranges
    if self.file_type == 'Cluster' && self.cluster_groups.any?
      cluster = self.cluster_groups.first
      # check if range values are present and set accordingly
      if !self.x_axis_min.nil? && !self.x_axis_max.nil? && !self.y_axis_min.nil? && !self.y_axis_max.nil?
        domain_ranges = {
            x: [self.x_axis_min, self.x_axis_max],
            y: [self.y_axis_min, self.y_axis_max]
        }
        if !self.z_axis_min.nil? && !self.z_axis_max.nil?
          domain_ranges[:z] = [self.z_axis_min, self.z_axis_max]
        end
        cluster.update(domain_ranges: domain_ranges)
      else
        # either user has not supplied ranges or is deleting them, so clear entry for cluster_group
        cluster.update(domain_ranges: nil)
      end
    end
  end

  # depending on the file_type, configure correct sanitizer for name field
  def validate_name_by_file_type
    regex = ValidationTools::FILENAME_CHARS
    error = ValidationTools::FILENAME_CHARS_ERROR
    case self.file_type
    when /(Cluster|Gene List)/
      regex = ValidationTools::OBJECT_LABELS
      error = ValidationTools::OBJECT_LABELS_ERROR
    when 'Fastq'
      if self.human_data?
        regex = ValidationTools::OBJECT_LABELS
        error = ValidationTools::OBJECT_LABELS_ERROR
      end
    end
    if self.name !~ regex
      errors.add(:name, error)
    end
  end
end
