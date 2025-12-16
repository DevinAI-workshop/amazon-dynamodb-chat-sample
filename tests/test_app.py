# -*- coding: utf-8 -*-
import json
from http import HTTPStatus

import boto3


def test_get_all_comments(client):
    response = client.get('/chat/comments/all')

    print('test_get_all_comments:' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert 'response' in response.json


def test_get_latest_comment(client):
    response = client.get('/chat/comments/latest')

    print('test_get_latest_comment ;' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert 'response' in response.json


def test_get_range_comment(client):
    latest_seq_id = '1111'
    uri = ('/chat/comments/latest/' + latest_seq_id)
    response = client.get(uri)

    print('test_get_range_comment ;' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert 'response' in response.json


def test_put_add_comment(client):
    response = client.post('/chat/comments/add',
                           headers={'Content-Type': 'application/json'},
                           body=json.dumps({'name': 'oranie', 'comment': 'test done'}))

    ddb = boto3.resource('dynamodb', endpoint_url='http://127.0.0.1:8000')
    tbl = ddb.Table('chat')
    get_result = tbl.get_item(
        Key={
            'name': 'oranie',
            'time': str(response.json['time'])
        }
    )

    print('Get Item : ' + str(get_result))

    assert response.status_code == HTTPStatus.OK
    assert response.json['state'] == 'Commment add OK'
    assert 'time' in response.json
    assert 'oranie' in get_result['Item']['name']
    assert 'test done' in get_result['Item']['comment']


def test_diary_save(client):
    response = client.post('/diary/save',
                           headers={'Content-Type': 'application/json'},
                           body=json.dumps({
                               'user_name': 'test_user',
                               'original_name': 'oranie',
                               'original_time': '1234567890',
                               'comment': 'test diary entry',
                               'chat_room': 'chat'
                           }))

    print('test_diary_save:' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert response.json['state'] == 'Saved to diary OK'
    assert 'saved_time' in response.json


def test_diary_get_entries(client):
    response = client.get('/diary/entries/test_user')

    print('test_diary_get_entries:' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert 'response' in response.json


def test_diary_delete(client):
    save_response = client.post('/diary/save',
                                headers={'Content-Type': 'application/json'},
                                body=json.dumps({
                                    'user_name': 'delete_test_user',
                                    'original_name': 'oranie',
                                    'original_time': '1234567890',
                                    'comment': 'entry to delete',
                                    'chat_room': 'chat'
                                }))

    saved_time = save_response.json['saved_time']

    response = client.post('/diary/delete',
                           headers={'Content-Type': 'application/json'},
                           body=json.dumps({
                               'user_name': 'delete_test_user',
                               'saved_time': saved_time
                           }))

    print('test_diary_delete:' + str(response.json.items()))
    assert response.status_code == HTTPStatus.OK
    assert response.json['state'] == 'Deleted from diary OK'
