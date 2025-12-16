# -*- coding: utf-8 -*-
import logging
import os
import re

from chalice import Chalice, Response
from chalicelib.ddb import DdbChat
from chalicelib.ddb import DdbDiary
from chalicelib.ddb import create_connection

logging.basicConfig(format='%(levelname)s:%(message)s', level=logging.DEBUG)

app = Chalice(app_name='dynamodb-python-chat-sample')


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


@app.route('/diary/save', methods=['POST'], cors=True)
def diary_save():
    body = app.current_request.json_body
    logging.info('diary save POST request Body : %s', body)

    ddbTable = create_connection('diary')
    ddbclient = DdbDiary()

    response = ddbclient.saveToDiary(
        ddbTable,
        body['user_name'],
        body['original_name'],
        body['original_time'],
        body['comment'],
        body.get('chat_room', 'chat')
    )
    logging.info('diary save response is  : %s', response)

    return {'state': 'Saved to diary OK', 'saved_time': response['saved_time']}


@app.route('/diary/entries/{user_name}', methods=['GET'], cors=True)
def diary_entries_get(user_name):
    logging.info('diary entries GET request user_name : %s', user_name)

    ddbTable = create_connection('diary')
    ddbclient = DdbDiary()

    response = ddbclient.getDiaryEntries(ddbTable, user_name)
    logging.info('diary entries response : %s', response)

    return {'response': response}


@app.route('/diary/delete', methods=['POST'], cors=True)
def diary_delete():
    body = app.current_request.json_body
    logging.info('diary delete POST request Body : %s', body)

    ddbTable = create_connection('diary')
    ddbclient = DdbDiary()

    response = ddbclient.deleteDiaryEntry(
        ddbTable,
        body['user_name'],
        body['saved_time']
    )
    logging.info('diary delete response is  : %s', response)

    return {'state': 'Deleted from diary OK'}
