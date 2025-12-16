# -*- coding: utf-8 -*-
import json
import logging
import os
import re

import boto3
from chalice import Chalice, Response
from chalicelib.ddb import DdbChat
from chalicelib.ddb import create_connection

logging.basicConfig(format='%(levelname)s:%(message)s', level=logging.DEBUG)

app = Chalice(app_name='dynamodb-python-chat-sample')

# WebSocket connection manager
connections = {}


@app.route('/', cors=True)
def index():
    # server status check URI
    ddbTable = create_connection('chat')
    ddbclient = DdbChat()
    result = ddbclient.putComment(ddbTable, 'oranie', 'done', 'chat-room')
    logging.info(result)

    return {'status': 'server status is good!  ' + str(result)}


@app.route('/chat', cors=True)
def chat():
    # Demo html
    with open("./chalicelib/livechat.html", "r") as html:
        base_lines = html.read()
        if os.environ['API_ENDPOINT'] == 'localhost':
            logging.info('return local envroiment html')
            lines = base_lines
        else:
            logging.info('return dev envroiment html')
            lines = re.sub(
                'http://localhost:8080/', os.environ['API_ENDPOINT'], base_lines)

    return Response(body=str(lines), status_code=200,
                    headers={'Content-Type': 'text/html', "Access-Control-Allow-Origin": "*"})


@app.route('/chat/comments/add', methods=['POST'], cors=True)
def comment_add():
    body = app.current_request.json_body
    logging.info('add request POST request Body : %s', body)

    ddbTable = create_connection('chat')
    ddbclient = DdbChat()

    response = ddbclient.putComment(ddbTable, body['name'], body['comment'], 'chat')
    logging.info('add request response is  : %s', response)

    return {'state': 'Commment add OK', 'time': response['time']}


@app.route('/chat/comments/latest', methods=['GET'], cors=True)
def comment_list_get():
    ddbTable = create_connection('chat')
    ddbclient = DdbChat()

    response = ddbclient.getLatestComments(ddbTable, 'chat', 20)
    logging.info('latest response : %s', response)

    return {'response': response['Items']}


@app.route('/chat/comments/all', methods=['GET'], cors=True)
def comment_all_get():
    ddbTable = create_connection('chat')
    ddbclient = DdbChat()

    response = ddbclient.getAllComments(ddbTable, 'chat')

    return {'response': response}


@app.route('/chat/comments/latest/{latest_seq_id}', methods=['GET'], cors=True)
def comment_range_get(latest_seq_id):
    logging.info('latest comments GET request latest seq id : %s', latest_seq_id)

    # Increment redis streams data type latest seq id
    # To get next comments

    ddbTable = create_connection('chat')
    ddbclient = DdbChat()

    response = ddbclient.getRangeComments(ddbTable, 'chat', latest_seq_id)
    logging.info('latest comments next id response : %s', response)

    return {'response': response}


# WebSocket handlers
@app.on_ws_connect()
def ws_connect(event):
    connection_id = event.connection_id
    connections[connection_id] = {
        'room': 'default',
        'user': None
    }
    logging.info('WebSocket connected: %s', connection_id)


@app.on_ws_disconnect()
def ws_disconnect(event):
    connection_id = event.connection_id
    if connection_id in connections:
        user = connections[connection_id]['user']
        room = connections[connection_id]['room']
        if user:
            broadcast_to_room(room, {
                'type': 'user_left',
                'user': user
            }, event)
        del connections[connection_id]
    logging.info('WebSocket disconnected: %s', connection_id)


@app.on_ws_message()
def ws_message(event):
    connection_id = event.connection_id
    data = json.loads(event.body)
    logging.info('WebSocket message from %s: %s', connection_id, data)

    if data['type'] == 'join':
        connections[connection_id]['user'] = data['user']
        broadcast_to_room('default', {
            'type': 'user_joined',
            'user': data['user']
        }, event)

    elif data['type'] == 'comment':
        ddbTable = create_connection('chat')
        ddbclient = DdbChat()
        result = ddbclient.putComment(ddbTable, data['name'], data['comment'], 'chat')

        broadcast_to_room('default', {
            'type': 'new_comment',
            'name': data['name'],
            'comment': data['comment'],
            'time': result['time']
        }, event)

    elif data['type'] == 'typing':
        broadcast_to_room('default', {
            'type': 'typing',
            'user': data['user'],
            'is_typing': data['is_typing']
        }, event, exclude_connection=connection_id)


def broadcast_to_room(room, message, event, exclude_connection=None):
    """Broadcast message to all connections in a room"""
    endpoint_url = os.environ.get('WEBSOCKET_ENDPOINT')
    if not endpoint_url:
        domain = event.domain_name
        stage = event.stage
        endpoint_url = f'https://{domain}/{stage}'

    apigw_management = boto3.client(
        'apigatewaymanagementapi',
        endpoint_url=endpoint_url
    )

    stale_connections = []
    for conn_id, conn_data in connections.items():
        if conn_data['room'] == room and conn_id != exclude_connection:
            try:
                apigw_management.post_to_connection(
                    ConnectionId=conn_id,
                    Data=json.dumps(message)
                )
            except Exception as e:
                logging.warning('Failed to send to %s: %s', conn_id, e)
                stale_connections.append(conn_id)

    for conn_id in stale_connections:
        if conn_id in connections:
            del connections[conn_id]
