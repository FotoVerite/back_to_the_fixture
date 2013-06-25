# Extension to make it easy to read and write data to a file.

class BackToTheFixture

  # reference models with plural name
  def self.load_tree(file_paths, opts = {})

    raise "you must supply at least one file" if file_paths.nil?
    paths = Array.wrap(file_paths)
    paths.each do |path|
      collect_yaml_files(path).each do |file|
        read_yaml_file(Rails.root + file, true).each do |klass_name, records|
          prepare_records(klass_name, records, opts)
        end
      end
    end
    true
  end

  def self.dump_tree(opts)
    raise "you must pass a :template hash object or path to yaml" unless opts[:template]
    if opts[:template].is_a?(String)
      opts[:template] = read_yaml_file(opts[:template])
    end
    opts[:template_key] ||= opts[:template].keys.first
    if opts[:split]
      split and_save_records(opts)
    else
      save_records(opts)
    end
    return true
  end

    protected

    # <tt>collect_files</tt>
    # Takes a path and checks if it points to a directory.
    # If directory it collect all yaml files inside.
    # Else it wraps it in an array for internal use.
    def collect_files(path)
      if File.directory?(path)
        Dir[file  +  '*.yml*']
      else
        Array.wrap(path)
      end
    end

    # <tt>prepare_records</tt>
    # Prepares records with given options for creation method.
    def self.prepare_records(klass_name, records, opts)
      klass = class_name.to_s.classify.constantize
      klass_sym = class_name.underscore.downcase.pluralize.to_sym
      #Skip creaation if model is in except_models list
      return if opts[:except_models].present? && opts[:except_models].include?(klass_sym)
      # NB This seems out of place for the method. Better naming? Prepare database section?
      reset_sequence(opts[:reset_sequence])
      klass.destroy_all if opts[:destroy_all].present?
      records.each do |record|
        create_record(klass, record, parse_exception_attributes(opts))
      end
    end


    # <tt>reset_sequence</tt>
    # NB This needs to at the very least also handle PG and sqlite
    # Resets the primary key sequence to 1
    def self.reset_sequence(run = false)
      return unless run
      reset_mysql_sequence = "ALTER TABLE #{klass.table_name} AUTO_INCREMENT = 1;"
      ActiveRecord::Base.connection.execute(reset_mysql_sequence);
      if connection.respond_to?(:reset_pk_sequence!)
        connection.reset_pk_sequence!(klass.table_name)
      end
    end

  def self.parse_exception_attributes(opts)
    return unless opts[:except_attributes]
    (opts[:except_attributes][klass_sym] || []) |
    (opts[:except_attributes][:global] || [])
  end

  def self.create_record(klass, record, exceptions=nil)
    record = record.with_indifferent_access.except(*exceptions) if exceptions
    klass.create(record, :without_protection => true)
  end

  def self.split_and_save_records(opts)
    opts[:save_path] ||= 'fixtures/models/' + opts[:template_key].to_s.downcase
    FileUtils.mkdir_p(opts[:save_path]) unless File.exists? opts[:save_path]
    gather_records
    merge_records
    @records.each do |k,v|
      file = Rails.root + opts[:save_path] + "#{k.to_s.downcase}.yml"
      v = merge_fixtures(file, {k => v}) if opts[:merge]
      write_yaml_file(file, {k => v}, opts[:append])
    end
  end

  def self.save_records(opts)
    opts[:save_path] += 'fixtures/trees/'
    opts[:save_name] ||= opts[:template_key].to_s.downcase + "_tree.yml"
    save_as = Rails.root + opts[:save_path] + opts[:save_name]
    FileUtils.touch(save_as) unless File.exists? save_as
    FileUtils.mkdir_p(opts[:save_path]) unless File.exists? opts[:save_path]
    gather_records
    merge_records
    write_yaml_file(save_as, @records, opts[:append])
  end

  def self.gather_records(opts)
    results = opts[:template][opts[:template_key]]
    @records = parse_template(nil, results)
  end

  def self.merge_records(opts)
    return unless opts[:merge]
    old_tree = read_yaml_file(save_as) || {}
    keys = @records.keys | old_tree.keys
    keys.each {|k| @records[k] = @records[k] | Array.wrap(old_tree[k])}
  end

  def self.merge_fixtures(file, records)
    old_tree = read_yaml_file(file) || nil
    keys = records.keys | old_tree.keys
    keys.each {|k| records[k] = records[k] | Array.wrap(old_tree[k])}
    return records
  end

  def self.read_yaml_file(file, parse = nil, pattern = '<%% %%>')
    raw_data = File.read(File.expand_path(file, Rails.root))
    data = Erubis::Eruby.new(raw_data, :pattern => pattern).result if parse
    YAML::load(data || raw_data)
  end

  # append won't work on trees; will need to use merge for those
  def self.write_yaml_file(file, records, append = nil)
    write_method = append ? 'a' : 'w'
    File.open(file, write_method) do |f|
      yaml = records.to_yaml(:SortKeys => true)
      if append
        yaml = records.values.first.to_yaml(:SortKeys => true) if records.is_a?(Hash)
        yaml = yaml.lines.map{|line| line unless line == "---\n"}.join
      end
      f.write yaml
    end
  end

  def self.build_relations(results, hash_template)
    results = results.scoped
    results = results.send('where', hash_template[:where]) if hash_template[:where].present?
    results = results.send('order', hash_template[:order]) if hash_template[:order].present?
    results = results.send('limit', hash_template[:query_limit]) if hash_template[:query_limit].present?
    if hash_template[:limit_by].present?
      hash =  results.group_by(&hash_template[:limit_by].keys.first)
      hash.each {|k,v| hash[k] = v.take(hash_template[:limit_by].values.first)}
      results = hash.values.flatten
    end
    results = results.send('take', hash_template[:hard_limit]) if hash_template[:hard_limit].present?
  end

  def self.parse_template(record, items, records={})
    items = Array.wrap(items)
    items.each do |item|

      if item.class == Symbol # like :events
        hash_template = {}
        if record.nil?
          results = item.to_s.classify.constantize.scoped
        else
          results = record.send(item)
        end
      else # else it's a hash, like {:user => [:posts]}; single k/v

        hash_template = item[item.keys.first]
        if record.nil?
          results = item.keys.first.to_s.classify.constantize.scoped
        else
          results = record.send(item.keys.first)
        end
      end

      if results.respond_to?(:each)
        results = build_relations
        result_class = results.first.class.to_s
      else
        result_class = results.class.to_s
      end
      Array.wrap(results).each do |result|
        records = parse_template(result, hash_template[:grab], records)
        h_result = hash_template[:sanitize] ? result.attributes : santize_result
        result_array.push h_result.to_hash
      end
      if result_array.empty?
      # do nothing
      elsif records[klass].nil?
        records[klass] = result_array
      else
        records[klass].concat result_array
      end
    end
    records
  end

  def self.sanitize_results(result, opts)
    hash_template[:sanitize].each_pair {|k,v|
      hash_template[:sanitize][k] = Erubis::Eruby.new(v, :pattern => '<%%% %%%>').result
    }
    result.attributes.with_indifferent_access.merge!(hash_template[:sanitize])
  end

end #class