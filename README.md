sequel_temporal
=================

Temporal versioning for sequel.

Dependencies
------------

* Ruby >= 1.9.2
* gem "sequel", "~> 3.30.0"

Usage
-----

* Declare temporality inside your model:

        class HotelPriceVersion < Sequel::Model
        end

        class HotelPrice < Sequel::Model
          plugin :temporal, version_class: HotelPriceVersion
        end

* You can now create a hotel price with versions:

        price = HotelPrice.new
        price.update_attributes price: 18

* To show all versions:

        price.versions

* To get current version:

        price.current_version

* Look at the specs for more usage patterns.

Build Status
------------

[![Build Status](http://travis-ci.org/TalentBox/sequel_bitemporal.png)](http://travis-ci.org/TalentBox/sequel_bitemporal)

License
-------

sequel_temporal is Copyright © 2011 TalentBox SA. It is free software, and may be redistributed under the terms specified in the LICENSE file.
