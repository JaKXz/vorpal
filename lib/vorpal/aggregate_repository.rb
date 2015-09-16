require 'vorpal/identity_map'
require 'vorpal/aggregate_utils'
require 'vorpal/db_loader'
require 'vorpal/db_driver'

module Vorpal
  class AggregateRepository
    # @private
    def initialize(db_driver, master_config)
      @db_driver = db_driver
      @configs = master_config
    end

    # Saves an aggregate to the DB. Inserts objects that are new to the
    # aggregate, updates existing objects and deletes objects that are no longer
    # present.
    #
    # Objects that are on the boundary of the aggregate (owned: false) will not
    # be inserted, updated, or deleted. However, the relationships to these
    # objects (provided they are stored within the aggregate) will be saved.
    #
    # @param root [Object] Root of the aggregate to be saved.
    # @return [Object] Root of the aggregate.
    def persist(root)
      persist_all([root]).first
    end

    # Like {#persist} but operates on multiple aggregates. Roots must
    # be of the same type.
    #
    # @param roots [[Object]] array of aggregate roots to be saved.
    # @return [[Object]] array of aggregate roots.
    def persist_all(roots)
      return roots if roots.empty?
      raise InvalidAggregateRoot, 'Nil aggregate roots are not allowed.' if roots.any?(&:nil?)

      all_owned_objects = all_owned_objects(roots)
      mapping = {}
      loaded_db_objects = load_owned_from_db(roots.map(&:id).compact, roots.first.class)

      serialize(all_owned_objects, mapping, loaded_db_objects)
      new_objects = get_unsaved_objects(mapping.keys)
      begin
        set_primary_keys(all_owned_objects, mapping)
        set_foreign_keys(all_owned_objects, mapping)
        remove_orphans(mapping, loaded_db_objects)
        save(all_owned_objects, new_objects, mapping)

        return roots
      rescue Exception
        nil_out_object_ids(new_objects)
        raise
      end
    end

    # Loads an aggregate from the DB. Will eagerly load all objects in the
    # aggregate and on the boundary (owned: false).
    #
    # @param db_root [Object] DB representation of the root of the aggregate to be
    #   loaded.
    # @param domain_class [Class] Type of the root of the aggregate to
    #   be loaded.
    # @param identity_map [Vorpal::IdentityMap] Provide your own IdentityMap instance
    #   if you want entity id - unique object mapping for a greater scope than one
    #   operation.
    # @return [Object] Aggregate root corresponding to the given DB representation.
    def load_one(db_root, domain_class, identity_map=IdentityMap.new)
      load_many(Array(db_root), domain_class, identity_map).first
    end

    # Like {#load_one} but operates on multiple aggregate roots.
    #
    # @param db_roots [[Integer]] Array of primary key values of the roots of the
    #   aggregates to be loaded.
    # @param domain_class [Class] Type of the roots of the aggregate to be loaded.
    # @param identity_map [Vorpal::IdentityMap] Provide your own IdentityMap instance
    #   if you want entity id - unique object mapping for a greater scope than one
    #   operation.
    # @return [[Object]] Aggregate roots corresponding to the given DB representations.
    def load_many(db_roots, domain_class, identity_map=IdentityMap.new)
      raise InvalidAggregateRoot, 'Nil aggregate roots are not allowed.' if db_roots.any?(&:nil?)

      loaded_db_objects = DbLoader.new(false, @db_driver).load_from_db_objects(db_roots, @configs.config_for(domain_class))
      deserialize(loaded_db_objects, identity_map)
      set_associations(loaded_db_objects, identity_map)

      db_roots.map { |db_object| identity_map.get(db_object) }
    end

    # Removes an aggregate from the DB. Even if the aggregate contains unsaved
    # changes this method will correctly remove everything.
    #
    # @param root [Object] Root of the aggregate to be destroyed.
    # @return [Object] Root that was passed in.
    def destroy(root)
      destroy_all([root]).first
    end

    # Like {#destroy} but operates on multiple aggregates. Roots must
    # be of the same type.
    #
    # @param roots [[Object]] Array of roots of the aggregates to be destroyed.
    # @return [[Object]] Roots that were passed in.
    def destroy_all(roots)
      return roots if roots.empty?
      raise InvalidAggregateRoot, 'Nil aggregate roots are not allowed.' if roots.any?(&:nil?)

      destroy_all_by_id(roots.map(&:id), roots.first.class)
      roots
    end

    # Removes an aggregate from the DB given its primary key.
    #
    # @param id [Integer] Id of root of the aggregate to be destroyed.
    # @param domain_class [Class] Type of the root of the aggregate to
    #   be destroyed.
    def destroy_by_id(id, domain_class)
      destroy_all_by_id([id], domain_class)
    end

    # Like {#destroy_by_id} but operates on multiple ids. Roots must
    # be of the same type.
    #
    # @param ids [[Integer]] Ids of roots of the aggregates to be destroyed.
    # @param domain_class [Class] Type of the roots of the aggregates to
    #   be destroyed.
    def destroy_all_by_id(ids, domain_class)
      raise InvalidPrimaryKeyValue, 'Nil primary key values are not allowed.' if ids.any?(&:nil?)

      loaded_db_objects = load_owned_from_db(ids, domain_class)
      loaded_db_objects.each do |config, db_objects|
        @db_driver.destroy(config, db_objects.map(&:id))
      end
      ids
    end

    # Returns the DB Class (e.g. ActiveRecord::Base class) that is responsible
    # for accessing the associated data in the DB.
    def db_class(domain_class)
      @configs.config_for(domain_class).db_class
    end

    private

    def all_owned_objects(roots)
      AggregateUtils.group_by_type(roots, @configs)
    end

    def load_from_db(ids, domain_class, only_owned=false)
      DbLoader.new(only_owned, @db_driver).load_from_db(ids, @configs.config_for(domain_class))
    end

    def load_owned_from_db(ids, domain_class)
      load_from_db(ids, domain_class, true)
    end

    def deserialize(loaded_db_objects, identity_map)
      loaded_db_objects.flat_map do |config, db_objects|
        db_objects.map do |db_object|
          # TODO: There is a bug here when you have something in the IdentityMap that is stale and needs to be updated.
          identity_map.get_and_set(db_object) { config.deserialize(db_object) }
        end
      end
    end

    def set_associations(loaded_db_objects, identity_map)
      loaded_db_objects.each do |config, db_objects|
        db_objects.each do |db_object|
          config.local_association_configs.each do |association_config|
            db_remote = loaded_db_objects.find_by_id(
              association_config.remote_class_config(db_object),
              association_config.fk_value(db_object)
            )
            association_config.associate(identity_map.get(db_object), identity_map.get(db_remote))
          end
        end
      end
    end

    def serialize(owned_objects, mapping, loaded_db_objects)
      owned_objects.each do |config, objects|
        objects.each do |object|
          db_object = serialize_object(object, config, loaded_db_objects)
          mapping[object] = db_object
        end
      end
    end

    def serialize_object(object, config, loaded_db_objects)
      if config.serialization_required?
        attributes = config.serialize(object)
        if object.id.nil?
          config.build_db_object(attributes)
        else
          db_object = loaded_db_objects.find_by_id(config, object.id)
          config.set_db_object_attributes(db_object, attributes)
          db_object
        end
      else
        object
      end
    end

    def set_primary_keys(owned_objects, mapping)
      owned_objects.each do |config, objects|
        in_need_of_primary_keys = objects.find_all { |obj| obj.id.nil? }
        primary_keys = @db_driver.get_primary_keys(config, in_need_of_primary_keys.length)
        in_need_of_primary_keys.zip(primary_keys).each do |object, primary_key|
          mapping[object].id = primary_key
          object.id = primary_key
        end
      end
      mapping.rehash # needs to happen because setting the id on an AR::Base model changes its hash value
    end

    def set_foreign_keys(owned_objects, mapping)
      owned_objects.each do |config, objects|
        objects.each do |object|
          config.has_manys.each do |has_many_config|
            if has_many_config.owned
              children = has_many_config.get_children(object)
              children.each do |child|
                has_many_config.set_foreign_key(mapping[child], object)
              end
            end
          end

          config.has_ones.each do |has_one_config|
            if has_one_config.owned
              child = has_one_config.get_child(object)
              has_one_config.set_foreign_key(mapping[child], object)
            end
          end

          config.belongs_tos.each do |belongs_to_config|
            child = belongs_to_config.get_child(object)
            belongs_to_config.set_foreign_key(mapping[object], child)
          end
        end
      end
    end

    def save(owned_objects, new_objects, mapping)
      grouped_new_objects = new_objects.group_by { |obj| @configs.config_for(obj.class) }
      owned_objects.each do |config, objects|
        objects_to_insert = grouped_new_objects[config] || []
        db_objects_to_insert = objects_to_insert.map { |obj| mapping[obj] }
        @db_driver.insert(config, db_objects_to_insert)

        objects_to_update = objects - objects_to_insert
        db_objects_to_update = objects_to_update.map { |obj| mapping[obj] }
        @db_driver.update(config, db_objects_to_update)
      end
    end

    def remove_orphans(mapping, loaded_db_objects)
      db_objects_in_aggregate = mapping.values
      db_objects_in_db = loaded_db_objects.all_objects
      all_orphans = db_objects_in_db - db_objects_in_aggregate
      grouped_orphans = all_orphans.group_by { |o| @configs.config_for_db_object(o) }
      grouped_orphans.each do |config, orphans|
        @db_driver.destroy(config, orphans)
      end
    end

    def get_unsaved_objects(objects)
      objects.find_all { |object| object.id.nil? }
    end

    def nil_out_object_ids(objects)
      objects ||= []
      objects.each { |object| object.id = nil }
    end
  end

  class InvalidPrimaryKeyValue < StandardError
  end
  class InvalidAggregateRoot < StandardError
  end
end
