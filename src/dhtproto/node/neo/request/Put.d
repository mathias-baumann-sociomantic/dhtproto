/*******************************************************************************

    Put request protocol.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module dhtproto.node.neo.request.Put;

/*******************************************************************************

    v0 Put request protocol.

*******************************************************************************/

public abstract scope class PutProtocol_v0
{
    import swarm.neo.node.RequestOnConn;
    import dhtproto.common.Put;
    import dhtproto.node.neo.request.core.Mixins;

    import ocean.transition;

    /***************************************************************************

        Mixin the constructor and resources member.

    ***************************************************************************/

    mixin RequestCore!();

    /***************************************************************************

        Request handler. Reads the record to be put from the client, adds it to
        the storage engine, and responds to the client with a status code.

        Params:
            connection = connection to client
            msg_payload = initial message read from client to begin the request
                (the request code and version are assumed to be extracted)

    ***************************************************************************/

    final public void handle ( RequestOnConn connection, Const!(void)[] msg_payload )
    {
        auto ed = connection.event_dispatcher();

        auto channel = ed.message_parser.getArray!(char)(msg_payload);
        auto key = *ed.message_parser.getValue!(hash_t)(msg_payload);
        auto value = ed.message_parser.getArray!(void)(msg_payload);

        RequestStatusCode response;

        // Check record key and write to channel, if ok.
        if ( this.responsibleForKey(key) )
        {
            response = this.put(channel, key, value)
                ? RequestStatusCode.Put : RequestStatusCode.Error;
        }
        else
            response = RequestStatusCode.WrongNode;

        // Send status code
        ed.send(
            ( ed.Payload payload )
            {
                payload.add(response);
            }
        );
    }

    /***************************************************************************

        Checks whether the node is responsible for the specified key.

        Params:
            key = key of record to write

        Returns:
            true if the node is responsible for the key

    ***************************************************************************/

    abstract protected bool responsibleForKey ( hash_t key );

    /***************************************************************************

        Writes a single record to the storage engine.

        Params:
            channel = channel to write to
            key = key of record to write
            value = record value to write

        Returns:
            true if the record was written; false if an error occurred

    ***************************************************************************/

    abstract protected bool put ( cstring channel, hash_t key, in void[] value );
}
