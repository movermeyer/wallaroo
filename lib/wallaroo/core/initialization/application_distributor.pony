/*

Copyright 2017 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "collections"
use "files"
use "net"
use "wallaroo_labs/dag"
use "wallaroo_labs/messages"
use "wallaroo"
use "wallaroo/core/common"
use "wallaroo/ent/recovery"
use "wallaroo_labs/mort"
use "wallaroo/core/messages"
use "wallaroo/core/metrics"
use "wallaroo/core/source/tcp_source"
use "wallaroo/core/topology"

actor ApplicationDistributor is Distributor
  let _auth: AmbientAuth
  let _step_id_gen: StepIdGenerator = StepIdGenerator
  let _local_topology_initializer: LocalTopologyInitializer
  let _application: Application val

  new create(auth: AmbientAuth, application: Application val,
    local_topology_initializer: LocalTopologyInitializer)
  =>
    _auth = auth
    _local_topology_initializer = local_topology_initializer
    _application = application

  be distribute(cluster_initializer: (ClusterInitializer | None),
    worker_count: USize, worker_names: Array[String] val,
    initializer_name: String)
  =>
    @printf[I32]("Initializing application\n".cstring())
    _distribute(_application, cluster_initializer, worker_count,
      worker_names, initializer_name)

  be topology_ready() =>
    @printf[I32]("Application has successfully initialized.\n".cstring())

  fun ref _distribute(application: Application val,
    cluster_initializer: (ClusterInitializer | None), worker_count: USize,
    worker_names: Array[String] val, initializer_name: String)
  =>
    @printf[I32]("---------------------------------------------------------\n".cstring())
    @printf[I32]("vvvvvv|Initializing Topologies for Workers|vvvvvv\n\n".cstring())

    try
      let all_workers_trn = recover trn Array[String] end
      all_workers_trn.push(initializer_name)
      for w in worker_names.values() do all_workers_trn.push(w) end
      let all_workers: Array[String] val = consume all_workers_trn

      // Keep track of all steps in the cluster and their proxy addresses.
      // This includes sinks but not sources, since we never send a message
      // directly to a source. For a sink, we don't keep a proxy address but
      // a step id (U128), since every worker will have its own instance of
      // that sink.
      let step_map = recover trn Map[U128, (ProxyAddress | U128)] end

      // Keep track of shared state so that it's only created once
      let state_partition_map =
        recover trn Map[String, PartitionAddresses val] end

      // Keep track of all prestate data so we can register routes
      let pre_state_data = recover trn Array[PreStateData] end

      // This will be incremented as we move through pipelines
      var pipeline_id: USize = 0

      // Map from step_id to worker name
      let steps: Map[U128, String] = steps.create()

      // TODO: Replace this when POC default target strategy is updated
      // Map from worker name to default target
      let default_targets:
        Map[String, (Array[StepBuilder] val | ProxyAddress)]
          = default_targets.create()

      // We use these graphs to build the local graphs for each worker
      var local_graphs = recover trn Map[String, Dag[StepInitializer] trn] end

      // Initialize values for local graphs
      local_graphs(initializer_name) = Dag[StepInitializer]
      for name in worker_names.values() do
        local_graphs(name) = Dag[StepInitializer]
      end

      // Edges that must be added at the end (because we need to create the
      // edge at the time the producer node is created, in which case the
      // target node will not yet exist).
      // Map from worker name to all (from_id, to_id) pairs
      let unbuilt_edges: Map[String, Array[(U128, U128)]] =
        unbuilt_edges.create()
      for w in all_workers.values() do
        unbuilt_edges(w) = Array[(U128, U128)]
      end

      // Create StateSubpartitions

      let ssb_trn = recover trn Map[String, StateSubpartition] end
      for (s_name, p_builder) in application.state_builders().pairs() do
        ssb_trn(s_name) = p_builder.state_subpartition(all_workers)
      end
      let state_subpartitions: Map[String, StateSubpartition] val =
        consume ssb_trn

      // Keep track of sink ids
      let sink_ids: Array[U128] = sink_ids.create()

      // Keep track of proxy ids per worker
      let proxy_ids: Map[String, Map[String, U128]] = proxy_ids.create()


      @printf[I32](("Found " + application.pipelines.size().string() +
        " pipelines in application\n").cstring())

      // Add stepbuilders for each pipeline into LocalGraphs to distribute to
      // workers
      for pipeline in application.pipelines.values() do
        if not pipeline.is_coalesced() then
          @printf[I32](("Coalescing is off for " + pipeline.name() +
            " pipeline\n").cstring())
        end

        // Since every worker will have an instance of the sink, we record
        // the step id and not the proxy address in our step map if there
        // is a step id for this pipeline.
        match pipeline.sink_id()
        | let sid: U128 =>
          step_map(sid) = sid
        end

        // TODO: Replace this when we have a better post-POC default strategy.
        // This is set if we need a default target in this pipeline.
        // Currently there can only be one default target per topology.
        var pipeline_default_state_name = ""
        var pipeline_default_target_worker = ""

        @printf[I32](("The " + pipeline.name() + " pipeline has " +
          pipeline.size().string() + " uncoalesced runner builders\n")
          .cstring())


        ///////////
        /*
        For the current pipeline, the following code transforms the
        sequence of runner builders (corresponding to all computations
        defined via the API for that pipeline) into a sequence of
        runner builders corresponding to steps in the running application.

        If coalescing is on, we try to coalesce all contiguous sequences of
        stateless computations into single runner builders (of type
        RunnerSequenceBuilder). Each RunnerSequenceBuilder will correspond
        to a single step.

        We handle the runner builders for the source first. If coalescing
        is on, we take all contiguous stateless runner builders starting
        from the first and coalesce them into one RunnerSequenceBuilder.
        In the process of doing this, we store them in
        `source_runner_builders`, which we will then use to create the
        RunnerSequenceBuilder.

        We then go through the rest of the runner builders from the
        pipeline, coalescing contiguous sequences of stateless runner
        builders into single RunnerSequenceBuilders and adding them to
        `step_runner_builders`, which will be used to build the
        StepInitializers (1-to-1 between members of `step_runner_builders`
        and steps in the running application). As we iterate over
        contiguous stateless computations, we add them to
        `latest_runner_builders`, which will be used to construct the
        corresponding RunnerSequenceBuilder.

        Keep in mind the following important caveat:
        We can coalesce the prestate runner builder back onto the
        previous stateless computation, be we cannot currently do
        this is if the stateless computation is parallelized.
        Furthermore, we cannot coalesce anything back onto a prestate
        runner builder (since that is a partition boundary).

        In what follows note the following 2 points:

        1) `step_runner_builders` is a sequence of runner builders
        (including some we've coalesced here) that correspond
        1-to-1 to the actual steps in the topology.

        2) `latest_runner_builders` accumulates runner builders we
        are in the process of coalescing.  They will eventually be
        combined into a RunnerSequenceBuilder and placed as one
        unit into `step_runner_builders`, at which point we empty
        `latest_runner_builders` so we can use it for the next
        coalesced sequence.
        */
        ///////////

        //
        var handled_source_runners = false
        // Used to store the first sequence of contiguous stateless
        // computations as we accumulate them to eventually turn into a
        // RunnerSequenceBuilder. When coalescing is off, we only put a
        // single runner builder here.
        var source_runner_builders = recover trn Array[RunnerBuilder] end

        // We'll use this array when creating StepInitializers
        let step_runner_builders = recover trn Array[RunnerBuilder] end

        // Used to temporarily store contiguous stateless computations as
        // we accumulate them to eventually turn into a RunnerSequenceBuilder.
        // When coalescing is off, we do not use this since each computation
        // will correspond to a step.
        var latest_runner_builders = recover trn Array[RunnerBuilder] end

        // If any in a series of contiguous stateless computations is
        // to be parallelized and coalescing is on, we coalesce and
        // parallelize them all. We use `parallel_stateless` to keep track
        // of when one is found. This is reset after each runner builder
        // is added to step_runner_builders.
        var parallel_stateless = false

        for i in Range(0, pipeline.size()) do
          let r_builder =
            try
              pipeline(i)?
            else
              @printf[I32](" couldn't find pipeline for index\n".cstring())
              error
            end

          if r_builder.is_stateless_parallel() then
            parallel_stateless = true
            // We're done putting runners on the source since
            // the stateless partition will not be on the source
            handled_source_runners = true
          end

          if r_builder.is_stateful() then
            if handled_source_runners then
              // TODO: Remove the condition around this push once we've fixed
              // initialization so we can coalesce a pre state runner onto a
              // stateless partition
              if not parallel_stateless then
                latest_runner_builders.push(r_builder)
              end
              let seq_builder = RunnerSequenceBuilder(
                latest_runner_builders = recover Array[RunnerBuilder] end,
                parallel_stateless)
              step_runner_builders.push(seq_builder)

              // TODO: Remove this condition and push once we've fixed
              // initialization so we can coalesce a pre state runner onto a
              // stateless partition
              if parallel_stateless then
                step_runner_builders.push(r_builder)
              end

              // We're done with this coalesced sequence of runners, so
              // we set parallel_stateless to false to indicate we are back
              // to searching for a stateless partition.
              parallel_stateless = false
            else
              source_runner_builders.push(r_builder)
              handled_source_runners = true
            end
          elseif not pipeline.is_coalesced() then
            if handled_source_runners then
              step_runner_builders.push(r_builder)
              parallel_stateless = false
            else
              source_runner_builders.push(r_builder)
              handled_source_runners = true
            end
          // TODO: If the developer specified an id, then this needs to be on
          // a separate step to be accessed by multiple pipelines
          // elseif ??? then
          //   step_runner_builders.push(r_builder)
          //   handled_source_runners = true
          else
            if handled_source_runners then
              latest_runner_builders.push(r_builder)
            else
              source_runner_builders.push(r_builder)
            end
          end
        end

        if latest_runner_builders.size() > 0 then
          let seq_builder = RunnerSequenceBuilder(
            latest_runner_builders = recover Array[RunnerBuilder] end,
            parallel_stateless)
          step_runner_builders.push(seq_builder)
        end

        // Create Source Initializer and add it to the graph for the
        // initializer worker.
        let source_node_id = _step_id_gen()
        let source_seq_builder = RunnerSequenceBuilder(
            source_runner_builders = recover Array[RunnerBuilder] end)

        let source_partition_workers: (String | Array[String] val | None) =
          if source_seq_builder.is_prestate() then
            if source_seq_builder.is_multi() then
              if all_workers.size() > 1 then
                @printf[I32]("Multiworker Partition\n".cstring())
              end
              all_workers
            else
              initializer_name
            end
          else
            None
          end

        // If the source contains a prestate runner, then we might need
        // a pre state target id, None if not
        let source_pre_state_target_id: (U128 | None) =
          if source_seq_builder.is_prestate() then
            try
              step_runner_builders(0)?.id()
            else
              match pipeline.sink_id()
              | let sid: U128 =>
                // We need a sink on every worker involved in the
                // partition
                let egress_builder = EgressBuilder(pipeline.name(),
                  sid, pipeline.sink_builder())

                match source_partition_workers
                | let w: String =>
                  try
                    local_graphs(w)?.add_node(egress_builder, sid)
                  else
                    @printf[I32](("No graph for worker " + w + "\n").cstring())
                    error
                  end
                | let ws: Array[String] val =>
                  local_graphs(initializer_name)?.add_node(egress_builder,
                    sid)
                  for w in ws.values() do
                    try
                      local_graphs(w)?.add_node(egress_builder, sid)
                    else
                      @printf[I32](("No graph for worker " + w + "\n")
                        .cstring())
                      error
                    end
                  end
                // source_partition_workers shouldn't be None since we showed
                // that source_seq_builders.is_prestate() is true
                end

                sink_ids.push(sid)
              end

              pipeline.sink_id()
            end
          else
            None
          end

        if source_seq_builder.is_prestate() then
          let psd = PreStateData(source_seq_builder,
            source_pre_state_target_id)
          pre_state_data.push(psd)

          let state_builder =
            try
              application.state_builder(psd.state_name())?
            else
              @printf[I32]("Failed to find state builder for prestate.\n"
                .cstring())
              error
            end
          if state_builder.default_state_name() != "" then
            pipeline_default_state_name = state_builder.default_state_name()
            pipeline_default_target_worker = initializer_name
          end
        end

        let source_initializer = SourceData(source_node_id,
          pipeline.source_builder()?, source_seq_builder,
          pipeline.source_route_builder(),
          pipeline.source_listener_builder_builder(),
          source_pre_state_target_id)

        @printf[I32](("\nPreparing to spin up " + source_seq_builder.name() +
          " on source on initializer\n").cstring())

        try
          local_graphs(initializer_name)?.add_node(source_initializer,
            source_node_id)
        else
          @printf[I32]("problem adding node to initializer graph\n".cstring())
          error
        end

        // The last (node_id/s, StepInitializer) pair we created.
        // Gets set to None when we cross to the next worker since it
        // doesn't need to know its immediate cross-worker predecessor.
        // If the source has a prestate runner on it, then we set this
        // to None since it won't send directly to anything.
        var last_initializer: (U128 | Array[U128] | None) =
          if source_seq_builder.state_name() == "" then
            (source_node_id)
          else
            None
          end


        // Determine which steps go on which workers using boundary indices
        // Each worker gets a near-equal share of the total computations
        // in this naive algorithm
        let per_worker: USize =
          if step_runner_builders.size() <= worker_count then
            1
          else
            step_runner_builders.size() / worker_count
          end

        @printf[I32](("Each worker gets roughly " + per_worker.string() +
          " steps\n").cstring())

        // Each worker gets a boundary value. Let's say "initializer" gets 2
        // steps, "worker2" 2 steps, and "worker3" 3 steps. Then the boundaries
        // array will look like: [2, 4, 7]
        let boundaries: Array[USize] = boundaries.create()
        // Since we put the source on the first worker, start at -1 to
        // indicate that it gets one less step than everyone else (all things
        // being equal). per_worker must be at least 1, so the first worker's
        // boundary will be at least 0.
        var count: USize = 0
        for i in Range(0, worker_count) do
          count = count + per_worker

          // We don't want to cross a boundary to get to the worker
          // that is the "anchor" for the partition, so instead we
          // make sure it gets put on the same worker
          try
            match step_runner_builders(count)?
            | let pb: PartitionBuilder =>
              count = count + 1
            end
          end

          if (i == (worker_count - 1)) and
            (count < step_runner_builders.size()) then
            // Make sure we cover all steps by forcing the rest on the
            // last worker if need be
            boundaries.push(step_runner_builders.size())
          else
            let b = if count < step_runner_builders.size() then
              count
            else
              step_runner_builders.size()
            end
            boundaries.push(b)
          end
        end

        // Keep track of which runner_builder we're on in this pipeline
        var runner_builder_idx: USize = 0
        // Keep track of which worker's boundary we're using
        var boundaries_idx: USize = 0

        ///////////
        // WORKERS

        // For each worker, use its boundary value to determine which
        // runner_builders to use to create StepInitializers that will be
        // added to its local graph
        while boundaries_idx < boundaries.size() do
          let boundary =
            try
              boundaries(boundaries_idx)?
            else
              @printf[I32](("No boundary found for boundaries_idx " +
                boundaries_idx.string() + "\n").cstring())
              error
            end

          let worker =
            if boundaries_idx == 0 then
              initializer_name
            else
              try
                worker_names(boundaries_idx - 1)?
              else
                @printf[I32]("No worker found for idx %lu!\n".cstring(),
                  boundaries_idx)
                error
              end
            end
          // Keep track of which worker follows this one in order
          let next_worker: (String | None) =
            try
              worker_names(boundaries_idx)?
            else
              None
            end

          let local_proxy_ids = Map[String, U128]
          proxy_ids(worker) = local_proxy_ids
          if worker != initializer_name then
            local_proxy_ids(initializer_name) = _step_id_gen()
          end
          for w in worker_names.values() do
            if worker != w then
              local_proxy_ids(w) = _step_id_gen()
            end
          end

          // Make sure there are still runner_builders left in the pipeline.
          if runner_builder_idx < step_runner_builders.size() then
            // Until we hit the boundary for this worker, keep adding
            // stepinitializers from the pipeline
            while runner_builder_idx < boundary do
              var next_runner_builder: RunnerBuilder =
                try
                  step_runner_builders(runner_builder_idx)?
                else
                  @printf[I32](("No runner builder found for idx " +
                    runner_builder_idx.string() + "\n").cstring())
                  error
                end

              if next_runner_builder.is_prestate() then
              //////////////////////////
              // PRESTATE RUNNER BUILDER
                // Determine which workers will be involved in this partition
                let partition_workers: (String | Array[String] val) =
                  if next_runner_builder.is_multi() then
                    if all_workers.size() > 1 then
                      @printf[I32]("Multiworker Partition\n".cstring())
                    end
                    all_workers
                  else
                    worker
                  end

                let pre_state_target_id: (U128 | None) =
                  try
                    step_runner_builders(runner_builder_idx + 1)?.id()
                  else
                    match pipeline.sink_id()
                    | let sid: U128 =>
                      // We need a sink on every worker involved in the
                      // partition
                      let egress_builder = EgressBuilder(pipeline.name(),
                        sid, pipeline.sink_builder())

                      match partition_workers
                      | let w: String =>
                        try
                          local_graphs(w)?.add_node(egress_builder, sid)
                        else
                          @printf[I32](("No graph for worker " + w + "\n")
                            .cstring())
                          error
                        end
                      | let ws: Array[String] val =>
                        local_graphs(initializer_name)?.add_node(egress_builder,
                          sid)
                        for w in ws.values() do
                          try
                            local_graphs(w)?.add_node(egress_builder, sid)
                          else
                            @printf[I32](("No graph for worker " + w + "\n")
                              .cstring())
                            error
                          end
                        end
                      end

                      sink_ids.push(sid)
                    end

                    pipeline.sink_id()
                  end

                @printf[I32](("Preparing to spin up prestate step " +
                  next_runner_builder.name() + " on " + worker + "\n")
                  .cstring())

                let psd = PreStateData(next_runner_builder,
                  pre_state_target_id)
                pre_state_data.push(psd)

                let state_builder =
                  try
                    application.state_builder(psd.state_name())?
                  else
                    @printf[I32]("Failed to find state builder for prestate.\n"
                      .cstring())
                    error
                  end

                // TODO: Update this approach when we create post-POC default
                // strategy.
                // ASSUMPTION: There is only one partititon default target
                // per application.
                if state_builder.default_state_name() != "" then
                  pipeline_default_state_name =
                    state_builder.default_state_name()
                  pipeline_default_target_worker = "worker"
                end

                let next_id = next_runner_builder.id()
                let next_initializer = StepBuilder(application.name(),
                  worker, pipeline.name(), next_runner_builder,
                  next_id where pre_state_target_id' = pre_state_target_id)
                step_map(next_id) = ProxyAddress(worker, next_id)
                try
                  local_graphs(worker)?.add_node(next_initializer, next_id)
                  local_graphs = _add_edges_to_graph(
                    last_initializer, local_graphs = recover Map[String,
                      Dag[StepInitializer] trn] end,
                    next_id, worker)?

                  // Pre state step uses a partition router and has no direct
                  // out, so don't connect an edge to the next node
                  last_initializer = None
                else
                  @printf[I32](("No graph for worker " + worker + "\n")
                    .cstring())
                  error
                end

                steps(next_id) = worker
              //////////////////////////////////////
              // PARALLELIZED STATELESS COMPUTATIONS
              elseif next_runner_builder.is_stateless_parallel() then
                // First we calculate the size of the partition and determine
                // where the steps in the partition go in the cluster. We are
                // populating three maps. Two of them, partition_id_to_worker
                // and partition_id_to_step_id, will be used to create a
                // StatelessPartitionRouter during local topology
                // initialization. The third, worker_to_step_id, will be used
                // here to determine which step ids we will put in which
                // local graphs.
                let pony_thread_count = @ponyint_sched_cores[I32]().usize()
                let partition_count = worker_count * pony_thread_count
                let partition_id_to_worker_trn =
                  recover trn Map[U64, String] end
                let partition_id_to_step_id_trn =
                  recover trn Map[U64, U128] end
                let worker_to_step_id_trn =
                  recover trn Map[String, Array[U128] trn] end
                for w in all_workers.values() do
                  worker_to_step_id_trn(w) = recover Array[U128] end
                end
                for id in Range[U64](0, partition_count.u64()) do
                  let step_id = _step_id_gen()
                  partition_id_to_step_id_trn(id) = step_id
                  let w = all_workers(id.usize() % worker_count)?
                  partition_id_to_worker_trn(id) = w
                  worker_to_step_id_trn(w)?.push(step_id)
                end
                let partition_id_to_worker: Map[U64, String] val =
                  consume partition_id_to_worker_trn
                let partition_id_to_step_id: Map[U64, U128] val =
                  consume partition_id_to_step_id_trn
                let worker_to_step_id_collector =
                  recover trn Map[String, Array[U128] val] end
                for (k, v) in worker_to_step_id_trn.pairs() do
                  match worker_to_step_id_trn(k) = recover Array[U128] end
                  | let arr: Array[U128] trn =>
                    worker_to_step_id_collector(k) = consume arr
                  end
                end
                let worker_to_step_id: Map[String, Array[U128] val] val =
                  consume worker_to_step_id_collector

                // Create a node in the graph for this worker
                // containing the blueprint for creating the stateless
                // partition router.
                let next_id = next_runner_builder.id()
                let psd = PreStatelessData(pipeline.name(), next_id,
                  partition_id_to_worker,
                  partition_id_to_step_id, worker_to_step_id)
                local_graphs(worker)?.add_node(psd, next_id)
                local_graphs = _add_edges_to_graph(
                  last_initializer, local_graphs = recover Map[String,
                    Dag[StepInitializer] trn] end,
                  next_id, worker)?

                // Keep track of all stateless partition computation ids
                // for this worker so we can connect their outputs to
                // the next step initializer (or egress) for this worker.
                let last_initializer_ids = Array[U128]

                // Get the id for the step that all stateless partition
                // computations will connect to as their output target.
                let successor_step_id: (U128 | None) =
                  if (runner_builder_idx + 1) < step_runner_builders.size()
                  then
                    step_runner_builders(runner_builder_idx + 1)?.id()
                  else
                    match pipeline.sink_id()
                    | let sink_id: U128 => sink_id
                    else
                      None
                    end
                  end

                // Add nodes for all stateless partition computations on
                // all workers.
                for w in all_workers.values() do
                  @printf[I32](("Preparing to spin up " +
                    next_runner_builder.name() + "stateless partition on " +
                    w + "\n").cstring())

                  if w != worker then
                    local_graphs(w)?.add_node(psd, next_id)
                  end

                  for s_id in worker_to_step_id(w)?.values() do
                    let next_initializer = StepBuilder(application.name(),
                      w, pipeline.name(), next_runner_builder, s_id)
                    step_map(s_id) = ProxyAddress(w, s_id)

                    try
                      local_graphs(w)?.add_node(next_initializer, s_id)
                      if w == worker then
                        last_initializer_ids.push(s_id)
                      else
                        match successor_step_id
                        | let ss_id: StepId =>
                          // We have not yet built the node corresponding
                          // to our successor step id (i.e. the node that
                          // this node has an edge to). So we keep track of
                          // that here and use that later, once we know
                          // all nodes have been added to the graphs.
                          unbuilt_edges(w)?.push((s_id, ss_id))
                        else
                          @printf[I32](("There is no step or sink after a " +
                            "stateless computation partition. This means " +
                            "unnecessary work is occurring in the topology." +
                            "\n").cstring())
                        end
                      end
                    else
                      @printf[I32](("No graph for worker " + worker + "\n")
                        .cstring())
                      error
                    end

                    steps(s_id) = worker
                  end

                  last_initializer = last_initializer_ids
                end
              else
              //////////////////////////////
              // NON-PRESTATE RUNNER BUILDER
                @printf[I32](("Preparing to spin up " +
                  next_runner_builder.name() + " on " + worker + "\n")
                  .cstring())
                let next_id = next_runner_builder.id()
                let next_initializer = StepBuilder(application.name(),
                  worker, pipeline.name(), next_runner_builder, next_id)
                step_map(next_id) = ProxyAddress(worker, next_id)

                try
                  local_graphs(worker)?.add_node(next_initializer, next_id)
                  local_graphs = _add_edges_to_graph(
                    last_initializer, local_graphs = recover Map[String,
                      Dag[StepInitializer] trn] end,
                    next_id, worker)?

                  last_initializer = next_id
                else
                  @printf[I32](("No graph for worker " + worker + "\n")
                    .cstring())
                  error
                end

                steps(next_id) = worker
              end

              runner_builder_idx = runner_builder_idx + 1
            end
            // We've reached the end of this worker's runner builders for this
            // pipeline
          end

          // Create the EgressBuilder for this worker and add to its graph.
          // First, check if there is going to be a step across the boundary
          if runner_builder_idx < step_runner_builders.size() then
          ///////
          // We need a Proxy since there are more steps to go in this
          // pipeline
            match next_worker
            | let w: String =>
              let next_runner_builder =
                try
                  step_runner_builders(runner_builder_idx)?
                else
                  @printf[I32](("No runner builder found for idx " +
                    runner_builder_idx.string() + "\n").cstring())
                  error
                end

              match next_runner_builder
              | let pb: PartitionBuilder =>
                @printf[I32](("A PartitionBuilder should never begin the " +
                  "chain on a non-initializer worker!\n").cstring())
                error
              else
                // Build our egress builder for the proxy
                let egress_id =
                  try
                    step_runner_builders(runner_builder_idx)?.id()
                  else
                    @printf[I32](("No runner builder found for idx " +
                      runner_builder_idx.string() + "\n").cstring())
                    error
                  end

                let proxy_address = ProxyAddress(w, egress_id)

                let egress_builder = EgressBuilder(pipeline.name(),
                  egress_id where proxy_addr = proxy_address)

                try
                  // If we've already created a node for this proxy, it
                  // will simply be overwritten (which effectively means
                  // there is one node per OutgoingBoundary)
                  local_graphs(worker)?.add_node(egress_builder, egress_id)
                  local_graphs = _add_edges_to_graph(
                    last_initializer, local_graphs = recover Map[String,
                      Dag[StepInitializer] trn] end,
                    egress_id, worker)?
                else
                  @printf[I32](("No graph for worker " + worker + "\n")
                    .cstring())
                  error
                end
              end
            else
              // Something went wrong, since if there are more runner builders
              // there should be more workers
              @printf[I32](("Not all runner builders were assigned to a " +
                "worker\n").cstring())
              error
            end
          else
          ///////
          // There are no more steps to go in this pipeline, so check if
          // we need a sink
            match pipeline.sink_id()
            | let sid: U128 =>
              let egress_builder = EgressBuilder(pipeline.name(),
                sid, pipeline.sink_builder())

              try
                // Add a sink to each worker
                for w in all_workers.values() do
                  local_graphs(w)?.add_node(egress_builder, sid)
                end
                // Add an edge for this worker
                local_graphs = _add_edges_to_graph(
                  last_initializer, local_graphs = recover Map[String,
                    Dag[StepInitializer] trn] end,
                  sid, worker)?
              else
                @printf[I32](("No graph for worker " + worker + "\n")
                  .cstring())
                error
              end

              sink_ids.push(sid)
            end
          end

          // Reset the last initializer since we're moving to the next worker
          last_initializer = None
          // Move to next worker's boundary value
          boundaries_idx = boundaries_idx + 1
          // Finished with this worker for this pipeline
        end

        ////////////////////////////////////////////////////////////////
        // HANDLE PARTITION DEFAULT STEP IF ONE EXISTS FOR THIS PIPELINE
        ////////
        // TODO: Replace this default strategy with a better one
        // after POC
        if pipeline_default_state_name != "" then
          @printf[I32]("-----We have a real default target name\n".cstring())
          match application.default_target
          | let default_target: Array[RunnerBuilder] val =>
            @printf[I32](("Preparing to spin up default target state on " +
              pipeline_default_target_worker + "\n").cstring())

            // The target will always be the sink (a stipulation of
            // the temporary POC strategy)
            match pipeline.sink_id()
            | let default_pre_state_target_id: U128 =>
              let pre_state_runner_builder =
                try
                  default_target(0)?
                else
                  @printf[I32]("Default target had no prestate value!\n"
                    .cstring())
                  error
                end

              let state_runner_builder =
                try
                  default_target(1)?
                else
                  @printf[I32]("Default target had no state value!\n"
                    .cstring())
                  error
                end

              let pre_state_id = pre_state_runner_builder.id()
              let state_id = state_runner_builder.id()

              // Add default prestate to PreStateData
              let psd = PreStateData(pre_state_runner_builder,
                default_pre_state_target_id, true)
              pre_state_data.push(psd)

              let pre_state_builder = StepBuilder(application.name(),
                pipeline_default_target_worker,
                pipeline.name(),
                pre_state_runner_builder, pre_state_id,
                false,
                default_pre_state_target_id,
                pre_state_runner_builder.forward_route_builder())

              @printf[I32](("Preparing to spin up default target state for " +
                state_runner_builder.name() + " on " +
                pipeline_default_target_worker + "\n").cstring())

              let state_builder = StepBuilder(application.name(),
                pipeline_default_target_worker,
                pipeline.name(),
                state_runner_builder, state_id,
                true
                where forward_route_builder' =
                  state_runner_builder.route_builder())

              steps(pre_state_id) = pipeline_default_target_worker
              steps(state_id) = pipeline_default_target_worker

              let next_default_targets = recover trn Array[StepBuilder] end

              next_default_targets.push(pre_state_builder)
              next_default_targets.push(state_builder)

              @printf[I32](("Adding default target for " +
                pipeline_default_target_worker + "\n").cstring())
              default_targets(pipeline_default_target_worker) =
                consume next_default_targets

              // Create ProxyAddresses for the other workers
              let proxy_address = ProxyAddress(pipeline_default_target_worker,
                pre_state_id)

              for w in worker_names.values() do
                default_targets(w) = proxy_address
              end
            else
              // We currently assume that a default step will target a sink
              // but apparently there is no sink for this pipeline
              Fail()
            end
          else
            @printf[I32]("----But no default target!\n".cstring())
          end
        end

        // Prepare to initialize the next pipeline
        pipeline_id = pipeline_id + 1
      end

      let sendable_step_map: Map[U128, (ProxyAddress | U128)] val =
        consume step_map

      let sendable_pre_state_data: Array[PreStateData] val =
        consume pre_state_data

      // Keep track of LocalTopologies that we need to send to other
      // (non-"initializer") workers
      let other_local_topologies = recover trn Map[String, LocalTopology] end

      // Add unbuilt edges
      for (w, edges) in unbuilt_edges.pairs() do
        for edge in edges.values() do
          try
            if not ((steps.contains(edge._2) and (steps(edge._2)? == w)) or
              sink_ids.contains(edge._2))
            then
              //We need a Proxy
              // Check if we have a corresponding egress builder node in the
              // graph for this worker already. If not, create one.
              if not local_graphs(w)?.contains(edge._2) then
                let target_worker = steps(edge._2)?
                let proxy_address = ProxyAddress(target_worker, edge._2)
                let egress_builder = EgressBuilder("All pipelines",
                  edge._2 where proxy_addr = proxy_address)
                local_graphs(w)?.add_node(egress_builder, edge._2)
              end
            end

            // Add this edge to the graph
            try
              local_graphs =
                _add_edges_to_graph(edge._1, local_graphs = recover
                  Map[String, Dag[StepInitializer] trn] end, edge._2, w)?
            else
              @printf[I32]("Error building unbuilt edge on %s!\n".cstring(),
                w.cstring())
              Fail()
            end
          else
            @printf[I32]("Unbuilt edge refers to nonexistent step id\n"
              .cstring())
            Fail()
          end
        end
      end

      // For each worker, generate a LocalTopology from its LocalGraph
      for (w, g) in local_graphs.pairs() do
        let p_ids = recover trn Map[String, U128] end
        for (target, p_id) in proxy_ids(w)?.pairs() do
          p_ids(target) = p_id
        end

        let default_target =
          try
            default_targets(w)?
          else
            @printf[I32](("No default target specified for " + w + "\n")
              .cstring())
            None
          end

        let local_topology =
          try
            LocalTopology(application.name(), w, g.clone()?,
              sendable_step_map, state_subpartitions, sendable_pre_state_data,
              consume p_ids, default_target, application.default_state_name,
              application.default_target_id,
              all_workers)
          else
            @printf[I32]("Problem cloning graph\n".cstring())
            error
          end

        // If this is the "initializer"'s (i.e. our) turn, then
        // immediately (asynchronously) begin initializing it. If not, add it
        // to the list we'll use to distribute to the other workers
        if w == initializer_name then
          _local_topology_initializer.update_topology(local_topology)
          _local_topology_initializer.initialize(cluster_initializer)
        else
          other_local_topologies(w) = local_topology
        end
      end

      // Distribute the LocalTopologies to the other (non-initializer) workers
      if worker_count > 1 then
        match cluster_initializer
        | let ci: ClusterInitializer =>
          ci.distribute_local_topologies(consume other_local_topologies)
        else
          @printf[I32]("Error distributing local topologies!\n".cstring())
        end
      end
      @printf[I32](("\n^^^^^^|Finished Initializing Topologies for " +
        "Workers|^^^^^^^\n").cstring())
      @printf[I32](("------------------------------------------------------" +
        "---\n").cstring())
    else
      @printf[I32]("Error initializing application!\n".cstring())
    end

  fun ref _add_edges_to_graph(producer_ids: (U128 | Array[U128] | None),
    local_graphs: Map[String, Dag[StepInitializer] trn] trn,
    target_id: U128, worker: String):
    Map[String, Dag[StepInitializer] trn] trn^ ?
  =>
    match producer_ids
    | let last_id: U128 =>
      local_graphs(worker)?.add_edge(last_id, target_id)?
    | let last_ids: Array[U128] =>
      for l_id in last_ids.values() do
        local_graphs(worker)?.add_edge(l_id, target_id)?
      end
    end
    consume local_graphs
