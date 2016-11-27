#!./node_modules/.bin/lsc -k

'use strict'

require! {
    'node-telegram-bot-api': Bot
    'mongoose'
    'bluebird': Promise
    './package.json': 'package_'
}

mongoose.Promise = Promise

mongoose.connect process.env.MONGOHQ_URL || "mongodb://localhost/#{package_.name}"

token = process.env.TELEGRAM_BOT_TOKEN
url = process.env.NOW_URL

bot = new Bot token,
    if url?
        web-hook:
            host: '0.0.0.0'
            port: process.env.PORT || 8000
    else
        polling : true


poll_schema = new mongoose.Schema do
    question:   type: String, required: true
    op_id:      type: String, required: true
    published:  type: [String], default: []
    created_at: type: Date, expires: '25h', default: Date.now


Poll = mongoose.model 'Poll' poll_schema

vote_schema = new mongoose.Schema do
    poll_id:    type: String, required: true
    user_id:    type: String, required: true
    vote:       type: String
    created_at: type: Date, expires: '25h'

Vote = mongoose.model 'Vote', vote_schema

const to-refresh = new Set

function voting-buttons-row (upvotes, downvotes, poll_id)
    return [
        * text: "+#upvotes"
          callback_data: JSON.stringify do
            act: 'vote'
            poll_id: poll_id
            vote: '+'
        * text: "-#downvotes"
          callback_data: JSON.stringify do
            act: 'vote'
            poll_id: poll_id
            vote: '-'
    ]


bot.on 'inline_query', (query) ->
    if query.query === '' 
        Poll.find do
            op_id: query.from.id
            published: $not: $size: 0
            'id question'
        .exec!
        .map (result) ->
            type: 'article'
            id: result.id
            title: result.question
            input_message_content:
                message_text: result.question
            reply_markup: inline_keyboard:
                voting-buttons-row '?', '?', result.id
                ...
        .then (results) ->
            bot.answer-inline-query do
                query.id
                results
                inline_query_id: query.id
                is_personal: true
                cache_time: 0
    else
        new Poll do
            question: query.query,
            op_id: query.from.id
        .save!
        .then (saved) ->
            bot.answer-inline-query do
                query.id,
                [
                    type: 'article'
                    id: saved.id
                    title: saved.question
                    description: 'New poll'
                    input_message_content:
                        message_text: saved.question
                    reply_markup: inline_keyboard:
                        voting-buttons-row 0, 0, saved.id
                        ...
                ]
                inline_query_id: query.id
                cache_time: 30
                is_personal: true

bot.on 'chosen_inline_result', (chosen_result) ->
    Poll.find-by-id chosen_result.result_id, 'published'
    .then (poll) ->
        to-refresh.add chosen_result.result_id if poll.published.length
        poll.published.push chosen_result.inline_message_id
        poll.save!

bot.on 'callback_query', (query) ->
    data = JSON.parse query.data
    switch data.act
        case 'vote'
            mongo-query =
                poll_id: data.poll_id
                user_id: query.from.id
            update =
                user_id: query.from.id
            options =
                upsert: true
                new: true
                set-defaults-on-insert: true
            Promise.join do
                Vote.find-one-and-update mongo-query, update, options
                Poll.find-by-id data.poll_id
            .spread (vote, poll) ->
                if not poll?
                    throw "Poll doesn't exist, probably expired"
                if vote.vote == data.vote
                    vote.vote = null
                    vote.save!
                    'Retracted vote'
                else
                    vote.vote = data.vote
                    vote.created_at = poll.created_at
                    vote.save!
                    {"+": "Up", "-": "Down"}[data.vote] + 'voted'
            .tap ->
                to-refresh.add(data.poll_id)
            .catch -> String it # turn exception into value
            .then (res) ->
                bot.answer-callback-query do
                    query.id
                    res
        default
            bot.answer-callback-query do
                query.id
                "Error: unknown act: #{data.act}"



bot.on-text //^/start//, (msg) ->
    bot.send-message do
        msg.chat.id
        """
        I'm bot for creating yes/no polls in inline mode.

        Polls expire 25 hours after being created.

        Created by @GingerPlusPlus.
        """
        reply_markup: inline_keyboard: [
            [
                * text: 'Create new poll'
                  switch_inline_query: ''
            ] [
                * text: 'Official group'
                  url: 'telegram.me/Rextesters'
                * text: 'Repository'
                  url: package_.repository.url
            ]
        ]



function refresh poll_id
    Promise.join do
        Poll.find-by-id poll_id
        Vote.count {poll_id, vote: '+'}
        Vote.count {poll_id, vote: '-'}
    .spread (poll, upvotes, downvotes) ->
        for msg_id in poll.published
            Promise.resolve bot.edit-message-text do
                """
                #{poll.question}

                Published #{poll.published.length} times
                """
                inline_message_id: msg_id
                reply_markup: inline_keyboard:
                    voting-buttons-row upvotes, downvotes, poll.id
                    ...
            .suppress-unhandled-rejections!


set-interval do
    ->
        to-refresh.for-each refresh
        to-refresh.clear!
    3000

console.info 'Bot started'
