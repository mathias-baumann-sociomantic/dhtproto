/*******************************************************************************

    Client DHT Put v0 request handler.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module dhtproto.client.request.internal.Put;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import ocean.util.log.Log;

/*******************************************************************************

    Module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("dhtproto.client.request.internal.Put");
}

/*******************************************************************************

    Put request implementation.

    Note that request structs act simply as namespaces for the collection of
    symbols required to implement a request. They are never instantiated and
    have no fields or non-static functions.

    The client expects several things to be present in a request struct:
        1. The static constants request_type and request_code
        2. The UserSpecifiedParams struct, containing all user-specified request
            setup (including a notifier)
        3. The Notifier delegate type
        4. Optionally, the Controller type (if the request can be controlled,
           after it has begun)
        5. The handler() function
        6. The all_finished_notifier() function

    The RequestCore mixin provides items 1 and 2.

*******************************************************************************/

public struct Put
{
    import dhtproto.common.Put;
    import dhtproto.client.request.Put;
    import dhtproto.common.RequestCodes;
    import swarm.neo.client.mixins.RequestCore;
    import swarm.neo.client.RequestHandlers;
    import swarm.neo.client.RequestOnConn;
    import dhtproto.client.internal.SharedResources;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    private static struct SharedWorking
    {
        public enum Result
        {
            Failure,
            NoNode,
            Error,
            Success
        }

        Result result;
    }

    /***************************************************************************

        Data which each request-on-conn needs while it is progress. An instance
        of this struct is stored per connection on which the request runs and is
        passed to the request handler.

    ***************************************************************************/

    private static struct Working
    {
        // Dummy (not required by this request)
    }

    /***************************************************************************

        Request core. Mixes in the types `NotificationInfo`, `Notifier`,
        `Params`, `Context` plus the static constants `request_type` and
        `request_code`.

    ***************************************************************************/

    mixin RequestCore!(RequestType.SingleNode, RequestCode.Put, 0, Args,
        SharedWorking, Working, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            use_node = delegate to get an EventDispatcher for the node with the
                specified address
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled
            working_blob = untyped chunk of data containing the serialized
                working data for the request on this connection

    ***************************************************************************/

    public static void handler ( UseNodeDg use_node, void[] context_blob,
        void[] working_blob )
    {
        auto context = Put.getContext(context_blob);
        context.shared_working.result = SharedWorking.Result.Failure;

        auto shared_resources = SharedResources.fromObject(
            context.request_resources.get());
        scope acquired_resources = shared_resources.new RequestResources;

        // Select the newest node reported to cover the record's hash
        auto nodes = shared_resources.node_hash_ranges.getNodesForHash(
            context.user_params.args.key,
            *acquired_resources.getNodeHashRangeBuffer());

        // Bail out if no nodes cover the record's hash
        if ( nodes.length == 0 )
        {
            context.shared_working.result = SharedWorking.Result.NoNode;
            return;
        }

        size_t newest;
        ulong newest_order;
        foreach ( i, node_hash_range; nodes )
        {
            if ( node_hash_range.order > newest_order )
            {
                newest = i;
                newest_order = node_hash_range.order;
            }
        }

        // Send Put request to selected node
        use_node(nodes[newest].addr,
            ( RequestOnConn.EventDispatcher conn )
            {
                putToNode(conn, context);
            }
        );
    }

    /***************************************************************************

        Puts the record passed by the user to the specified node.

        Params:
            conn = event dispatcher for the connection to send the record to
            context = deserialized request context, including record/value

    ***************************************************************************/

    private static void putToNode ( RequestOnConn.EventDispatcher conn,
        Put.Context* context )
    {
        try
        {
            // Send request info to node
            conn.send(
                ( conn.Payload payload )
                {
                    payload.add(Put.cmd.code);
                    payload.add(Put.cmd.ver);
                    payload.addArray(context.user_params.args.channel);
                    payload.add(context.user_params.args.key);
                    payload.addArray(context.user_params.args.value);
                }
            );

            // Receive status from node
            auto status = conn.receiveValue!(StatusCode)();
            if ( !Put.handleGlobalStatusCodes(status, context,
                conn.remote_address) )
            {
                switch ( status )
                {
                    case RequestStatusCode.Put:
                        context.shared_working.result =
                            SharedWorking.Result.Success;
                        break;

                    case RequestStatusCode.WrongNode:
                        context.shared_working.result =
                            SharedWorking.Result.Error;

                        // The node is not reponsible for the key. Notify the user.
                        Notification n;
                        n.wrong_node = RequestNodeInfo(context.request_id,
                            conn.remote_address);
                        Put.notify(context.user_params, n);
                        break;

                    case RequestStatusCode.Error:
                        context.shared_working.result =
                            SharedWorking.Result.Error;

                        // The node returned an error code. Notify the user.
                        Notification n;
                        n.node_error = RequestNodeInfo(context.request_id,
                            conn.remote_address);
                        Put.notify(context.user_params, n);
                        break;

                    default:
                        log.warn("Received unknown status code {} from node "
                            ~ "in response to Put request. Treating as "
                            ~ "Error.", status);
                        goto case RequestStatusCode.Error;
                }
            }
        }
        catch ( IOError e )
        {
            context.shared_working.result =
                SharedWorking.Result.Error;

            // A connection error occurred. Notify the user.
            auto info = RequestNodeExceptionInfo(context.request_id,
                conn.remote_address, e);

            Notification n;
            n.node_disconnected = info;
            Put.notify(context.user_params, n);
        }
    }

    /***************************************************************************

        Request finished notifier. Called from Request.handlerFinished().

        Params:
            context_blob = untyped chunk of data containing the serialized
                context of the request which is finishing
            working_data_iter = iterator over the stored working data associated
                with each connection on which this request was run

    ***************************************************************************/

    public static void all_finished_notifier ( void[] context_blob,
        IRequestWorkingData working_data_iter )
    {
        auto context = Put.getContext(context_blob);

        Notification n;

        with ( SharedWorking.Result ) switch ( context.shared_working.result )
        {
            case Success:
                n.success = RequestInfo(context.request_id);
                break;
            case NoNode:
                n.no_node = RequestInfo(context.request_id);
                break;
            case Failure:
                n.failure = RequestInfo(context.request_id);
                break;
            case Error:
                // Error notification was already handled in putToNode(),
                // where we have access to the node's address &/ exception.
                return;
            default:
                assert(false);
        }

        Put.notify(context.user_params, n);
    }
}
