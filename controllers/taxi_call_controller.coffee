# taxi call controller

class TaxiCallController
  constructor: ->

  ##
  # return taxis near current user.
  ##
  getNearTaxis: (req, res) ->
    taxis = []

    User.collection.find({ role: "driver", state:{$gte: 1}, taxi_state:1, location:{$exists: true} }).toArray (err, docs)->
      if err
        logger.warning("Service getNearTaxis - database error")
        return res.json { status: 3, message: "database error" }

      for doc in docs
        if doc.location
          # set default stats
          doc.stats = {average_score: 0, service_count: 0, evaluation_count: 0} unless doc.stats
          taxis.push
            phone_number: doc.phone_number
            name: doc.name
            car_number: doc.car_number
            longitude: doc.location[0]
            latitude: doc.location[1]
            stats: doc.stats

      res.json { status: 0, taxis: taxis }

  ##
  # create taxi call request
  ##
  create: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.key) &&
           req.json_data.driver && _.isString(req.json_data.driver) && !_.isEmpty(req.json_data.driver) &&
           (!req.json_data.origin || (_.isNumber(req.json_data.origin.longitude) && _.isNumber(req.json_data.origin.latitude) &&
                                      (!req.json_data.origin.name || (_.isString(req.json_data.origin.name) && !_.isEmpty(req.json_data.origin.name))))) &&
           (!req.json_data.destination || (_.isNumber(req.json_data.destination.longitude) && _.isNumber(req.json_data.destination.latitude) &&
                                           (!req.json_data.destination.name || (_.isString(req.json_data.destination.name) && !_.isEmpty(req.json_data.destination.name)))))
      logger.warning("Service create - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    User.collection.findOne {name: req.json_data.driver}, (err, doc) ->
      if !doc || doc.state == 0 || doc.taxi_state != 1
        logger.warning("Service create - driver #{req.json_data.driver} can't accept taxi call for now %s", doc)
        return res.json { status: 101, message: "driver can't accept taxi call for now" }

      # only one active service is allowed for a user at the same time
      Service.collection.findOne {passenger: req.current_user.name, $or:[{state:1}, {state:2}]}, (err, doc) ->
        # cancel existing services
        if doc
          Service.collection.update({_id: doc._id}, {$set: {state: -2}})
          # send cancel message to driver
          message =
            receiver: doc.driver
            type: "call-taxi-cancel"
            id: doc._id
            timestamp: new Date().valueOf()
          Message.collection.update({receiver: message.receiver, id:message.id, type: message.type}, message, {upsert: true})

        origin = if req.json_data.origin then [req.json_data.origin.longitude, req.json_data.origin.latitude, req.json_data.origin.name] else req.current_user.location
        destination = if req.json_data.destination then [req.json_data.destination.longitude, req.json_data.destination.latitude, req.json_data.destination.name] else null
        # create new service
        Service.uniqueID (id)->
          data =
            driver: req.json_data.driver
            passenger: req.current_user.name
            state: 1
            origin: origin
            destination: destination
            key: req.json_data.key
            _id: id
          Service.create data

          # send call-taxi message to driver
          message =
            receiver: req.json_data.driver
            type: "call-taxi"
            passenger:
              phone_number: req.current_user.phone_number
              name:req.current_user.name
            origin:
              longitude: origin[0]
              latitude: origin[1]
              name: origin[2]
            id: id
            timestamp: new Date().valueOf()
          message.destination = {longitude: destination[0], latitude: destination[1], name: destination[2]} if destination
          Message.collection.update({receiver: message.receiver, passenger:message.passenger, type: message.type}, message, {upsert: true})

          res.json { status: 0, id: id }

  ##
  # driver reply to a taxi call
  ##
  reply: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.id) && _.isBoolean(req.json_data.accept)
      logger.warning("Service reply - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    req.json_data.actor = req.current_user
    Service.reply req.json_data, (result)->
      res.json result

  ##
  # passenger cancel a taxi call
  ##
  cancel: (req, res) ->
    unless !_.isEmpty(req.json_data) && (_.isNumber(req.json_data.id) || _.isNumber(req.json_data.key))
      logger.warning("Service cancel - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    query = if req.json_data.id then {_id: req.json_data.id} else {key: req.json_data.key, passenger: req.current_user.name}

    Service.cancel query, req.current_user, (result) ->
      res.json result

  ##
  # driver notify the completion of a service
  ##
  complete: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.id)
      logger.warning("Service complete - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    req.json_data.actor = req.current_user
    Service.complete req.json_data, (result) ->
      res.json result

  ##
  # evaluate a service
  ##
  evaluate: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.id) && _.isNumber(req.json_data.score) &&
           (!req.json_data.comment || (_.isString(req.json_data.comment) && !_.isEmpty(req.json_data.comment)))
      logger.warning("Service evaluate - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    req.json_data.role = if _.include(req.current_user.role, "passenger") then "passenger" else "driver"
    req.json_data.evaluator = req.current_user.name
    Evaluation.create req.json_data, (result)->
      res.json result

  ##
  # get evaluations of specified services
  ##
  getEvaluations: (req, res) ->
    unless !_.isEmpty(req.json_data) && req.json_data.ids && _.isArray(req.json_data.ids) && !_.isEmpty(req.json_data.ids)
      logger.warning("Service getEvaluations - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    for id in req.json_data.ids
      unless _.isNumber(id)
        logger.warning("Service getEvaluations - incorrect data format %s", req.json_data)
        return res.json { status: 2, message: "incorrect data format" }

    Evaluation.collection.find({service_id:{$in: req.json_data.ids}}).toArray (err, docs)->
      if err
        logger.error("Service getEvaluations - database error")
        return res.json { status: 3, message: "database error" }

      result =  {status: 0}
      for evaluation in docs
        result[evaluation.service_id] = result[evaluation.service_id] || {}
        if evaluation.role == "passenger"
          result[evaluation.service_id]["passenger_evaluation"] = {score: evaluation.score, comment: evaluation.comment, created_at: evaluation.created_at.valueOf()}
        else
          result[evaluation.service_id]["driver_evaluation"] = {score: evaluation.score, comment: evaluation.comment, created_at: evaluation.created_at.valueOf()}

      res.json result

  ##
  # get evaluations of a user
  ##
  getUserEvaluations: (req, res) ->
    unless !_.isEmpty(req.json_data) && req.json_data.name && _.isString(req.json_data.name) && !_.isEmpty(req.json_data.name) &&
           _.isNumber(req.json_data.end_time) &&
           (_.isUndefined(req.json_data.count) || _.isNumber(req.json_data.count))
      logger.warning("Service getEvaluations - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    # set default count to 20
    req.json_data.count = req.json_data.count || 20

    User.collection.findOne {name: req.json_data.name}, (err, user) ->
      if err
        logger.error("Service getUserEvaluations - database error")
        return res.json { status: 3, message: "database error" }

      if !user
        logger.warning("getUserEvaluations - database error")
        return res.json { status: 101, message: "database error" }

      Evaluation.search {created_at: {$lte: new Date(req.json_data.end_time)}, "target":user.name}, {limit: req.json_data.count, sort:[['created_at', 'desc']]}, (result)->
        return res.json result

  ##
  # get history of services related to current user
  ##
  history: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.end_time) &&
           (_.isUndefined(req.json_data.count) || _.isNumber(req.json_data.count)) &&
           (_.isUndefined(req.json_data.start_time) || _.isNumber(req.json_data.start_time))
      logger.warning("Service history - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    # set default params
    req.json_data.count = req.json_data.count || 10
    req.json_data.start_time = req.json_data.start_time || new Date(2011, 11, 11)

    driver_query = {state: {$in: [-3, -2, -1, 3]}, driver: req.current_user.name, created_at:{$lte: new Date(req.json_data.end_time), $gte: new Date(req.json_data.start_time)}}
    passenger_query = {state: {$in: [-3, -2, -1, 3]}, passenger: req.current_user.name, created_at:{$lte: new Date(req.json_data.end_time), $gte: new Date(req.json_data.start_time)}}
    query = if _.include(req.current_user.role, "passenger") then passenger_query else driver_query

    Service.search query, {limit: req.json_data.count, sort:[['created_at', 'desc']]}, (result)->
      if _.include(req.current_user.role, "passenger")
        delete service.passenger for service in result.services
      else
        delete service.driver for service in result.services
      res.json result

  ##
  # update location physical name
  ##
  updateLocationName: (req, res) ->
    unless !_.isEmpty(req.json_data) && _.isNumber(req.json_data.id) &&
           _.isString(req.json_data.type) && (req.json_data.type == "origin" || req.json_data.type == "destination") &&
           _.isString(req.json_data.name) && !_.isEmpty(req.json_data.name)
      logger.warning("Service updateLocationName - incorrect data format %s", req.json_data)
      return res.json { status: 2, message: "incorrect data format" }

    Service.collection.findOne {_id: req.json_data.id}, (err, service) ->
      unless service
        logger.warning("Service updateLocationName - service not found %", req.json_data.id)
        return res.json { status: 101, message: "service not found" }

      unless _.isArray(service[req.json_data.type])
        logger.warning("Service updateLocationName - #{req.json_data.type} not found %", req.json_data.id)
        return res.json { status: 102, message: "#{req.json_data.type} not found" }

      location = [service.location[0], service.location[1], req.json_data.name]
      Service.collection.update({_id: req.json_data.id}, {$set:{location: location}})

      res.json { status: 0 }

module.exports = TaxiCallController
