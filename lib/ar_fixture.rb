class ActiveRecord::Base

  class << self

    # Writes content of this table to db/table_name.yml, or the specified file.
    #
    # Writes all content by default, but can be limited.
    def dump_to_file(path=nil, limit=nil, opts={})
      opts[:limit] = limit if limit
      path ||= "db/#{table_name}.yml"
      write_file(File.expand_path(path, Rails.root), self.find(:all, opts).to_yaml)
      habtm_to_file
    end

    # dump the habtm association table
    def habtm_to_file
      path ||= "db/#{table_name}.yml"
      joins = self.reflect_on_all_associations.select { |j|
        j.macro == :has_and_belongs_to_many
      }
      joins.each do |join|
        hsh = {}
        connection.select_all("SELECT * FROM #{join.options[:join_table]}").each_with_index { |record, i|
          hsh["join_#{'%05i' % i}"] = record
        }
        write_file(File.expand_path("db/#{join.options[:join_table]}.yml", Rails.root), hsh.to_yaml(:SortKeys => true))
      end
    end

    def load_from_file(path=nil)
      path ||= "fixtures/models/#{table_name}.yml"
      self.destroy_all
      reset_mysql_sequence = "ALTER TABLE #{self.table_name} AUTO_INCREMENT = 1;"
      ActiveRecord::Base.connection.execute(reset_mysql_sequence);

      raw_data = File.read(File.expand_path(path, Rails.root))
      erb_data = Erubis::Eruby.new(raw_data, :pattern => '<%% %%>').result
      records = YAML::load( erb_data )
      records.each do |name, record|
        unless 'test' == Rails.env
          puts "______________"
          puts record.to_yaml
          puts "______________"
        end

        record_copy = self.new(record,  :without_protection => true)

        # For Single Table Inheritance
        klass_col = self.inheritance_column
        if record[klass_col]
          record_copy.type = record[klass_col]
        end

        record_copy.save(:validate => false)
      end

      if connection.respond_to?(:reset_pk_sequence!)
        connection.reset_pk_sequence!(table_name)
      end
      true
    end


    # Write a file that can be loaded with +fixture :some_table+ in tests.
    # Uses existing data in the database.
    #
    # Will be written to +test/fixtures/table_name.yml+. Can be restricted to some number of rows.
    #

    # See tasks/ar_fixtures.rake for what can be done from the command-line, or use "rake -T" and look for items in the "db" namespace.

    def to_fixture(opts={})
      opts[:save_path] ||= "fixtures/models"
      opts[:save_name] ||= "#{table_name}.yml"
      write_method = opts[:append] ? 'a' : 'w'
      internal_opts = [:save_path, :save_name, :append]
      File.open(Rails.root + opts[:save_path] + opts[:save_name], write_method) do  |file|
        yaml = self.scoped.where(opts.except(*internal_opts)).inject({}) do |hsh, record|
          hsh.merge((record.attributes[opts[:key].to_s] || "#{self}-#{'%05i' % record.id rescue record.id}") => record.attributes)
        end.to_yaml(:SortKeys => true)
        if opts[:append]
          yaml = yaml.lines.map{|line| line unless line == "---\n"}.join
        end
        file.write yaml
      end
        #habtm_to_fixture
        return true
    end

    # Write the habtm association table
    def habtm_to_fixture(opts={save_path: "spec/fixtures/"})
      internal_opts = [:save_as]
      joins = self.reflect_on_all_associations.select { |j|
        j.macro == :has_and_belongs_to_many
      }
      joins.each do |join|
        hsh = {}
        connection.select_all("SELECT * FROM #{join.options[:join_table]}").each_with_index { |record, i|
          hsh["join_#{'%05i' % i}"] = record
        }
        write_file(File.expand_path(opts[:path] + "#{join.options[:join_table]}.yml", Rails.root), hsh.to_yaml(:SortKeys => true))
      end
    end

    # Generates a basic fixture file in test/fixtures that lists the table's field names.
    #
    # You can use it as a starting point for your own fixtures.
    #
    #  record_1:
    #    name:
    #    rating:
    #  record_2:
    #    name:
    #    rating:
    #
    # TODO Automatically add :id field if there is one.
    def to_skeleton(opts={save_path: "spec/fixtures/"})
      record = {
        "record_1" => self.new.attributes,
        "record_2" => self.new.attributes
      }
      write_file(File.expand_path(opts[:path] + "#{table_name}.yml", Rails.root),
      record.to_yaml)
    end

    def write_file(path, content) # :nodoc:
      f = File.new(path, "w+")
      f.puts content
      f.close
    end


  end
end