defmodule Level.Posts.CreateReply do
  @moduledoc """
  Responsible for creating a reply to post.
  """

  alias Ecto.Multi
  alias Level.Files
  alias Level.Groups
  alias Level.Mentions
  alias Level.Notifications
  alias Level.Posts
  alias Level.Repo
  alias Level.Schemas.Post
  alias Level.Schemas.PostLog
  alias Level.Schemas.Reply
  alias Level.Schemas.SpaceUser
  alias Level.StringHelpers
  alias Level.WebPush

  @typedoc "Dependencies injected in the perform function"
  @type options :: [
          presence: any(),
          web_push: any(),
          events: any()
        ]

  @typedoc "The result of calling the perform function"
  @type result :: {:ok, map()} | {:error, any(), any(), map()}

  @doc """
  Adds a reply to post.
  """
  @spec perform(SpaceUser.t(), Post.t(), map(), options()) :: result()
  def perform(%SpaceUser{} = author, %Post{} = post, params, opts) do
    Multi.new()
    |> do_insert(build_params(author, post, params))
    |> check_privacy(post)
    |> record_mentions(post, author)
    |> attach_files(author, params)
    |> log(post, author)
    |> record_post_view(post, author)
    |> Repo.transaction()
    |> after_transaction(post, author, opts)
  end

  @doc """
  Builds a payload for a push notifications.
  """
  @spec build_push_payload(Reply.t(), SpaceUser.t()) :: WebPush.Payload.t()
  def build_push_payload(%Reply{} = reply, %SpaceUser{} = author) do
    author = Repo.preload(author, :space)
    body = "@#{author.handle}: " <> StringHelpers.truncate(reply.body)
    %WebPush.Payload{title: author.space.name, body: body, tag: nil}
  end

  defp build_params(author, post, params) do
    params
    |> Map.put(:space_id, author.space_id)
    |> Map.put(:space_user_id, author.id)
    |> Map.put(:post_id, post.id)
  end

  defp do_insert(multi, params) do
    Multi.insert(multi, :reply, Reply.create_changeset(%Reply{}, params))
  end

  defp check_privacy(multi, post) do
    Multi.run(multi, :is_private, fn _ ->
      Posts.private?(post)
    end)
  end

  defp record_mentions(multi, post, author) do
    Multi.run(multi, :mentions, fn %{reply: reply} ->
      Mentions.record(author, post, reply)
    end)
  end

  defp attach_files(multi, author, %{file_ids: file_ids}) do
    Multi.run(multi, :files, fn %{reply: reply} ->
      files = Files.get_files(author, file_ids)
      Posts.attach_files(reply, files)
    end)
  end

  defp attach_files(multi, _, _) do
    Multi.run(multi, :files, fn _ -> {:ok, []} end)
  end

  defp log(multi, post, space_user) do
    Multi.run(multi, :log, fn %{reply: reply} ->
      PostLog.reply_created(post, reply, space_user)
    end)
  end

  def record_post_view(multi, post, space_user) do
    Multi.run(multi, :post_view, fn %{reply: reply} ->
      Posts.record_view(post, space_user, reply)
    end)
  end

  defp after_transaction({:ok, %{reply: reply} = result}, post, author, opts) do
    subscribe_author(post, author)
    subscribe_mentioned_users(post, result)
    subscribe_mentioned_groups(post, result)
    subscribe_watchers(post)
    record_reply_view(reply, author)

    {:ok, subscribers} = Posts.get_subscribers(post)

    mark_as_unread(post, reply, subscribers)
    record_notifications(reply, subscribers)
    send_push_notifications(post, reply, author, opts)

    send_events(post, result, opts)

    {:ok, result}
  end

  defp after_transaction(err, _, _, _), do: err

  defp subscribe_author(post, author) do
    Posts.subscribe(author, [post])
  end

  # This is not very efficient, but assuming that posts will not have too
  # many @-mentions, I'm not going to worry about the performance penalty
  # of performing a post lookup query for every mention (for now).
  defp subscribe_mentioned_users(post, %{mentions: %{space_users: mentioned_users}}) do
    Enum.each(mentioned_users, fn mentioned_user ->
      if can_access_post?(mentioned_user, post.id) do
        Posts.subscribe(mentioned_user, [post])
      end
    end)
  end

  defp subscribe_mentioned_groups(post, %{mentions: %{groups: mentioned_groups}}) do
    Enum.each(mentioned_groups, fn mentioned_group ->
      {:ok, group_users} = Groups.list_all_memberships(mentioned_group)
      group_users = Repo.preload(group_users, :space_user)

      Enum.each(group_users, fn group_user ->
        Posts.subscribe(group_user.space_user, [post])
      end)
    end)
  end

  defp subscribe_watchers(post) do
    post = Repo.preload(post, :groups)

    post.groups
    |> Enum.each(fn group ->
      {:ok, watching_group_users} = Groups.list_all_watchers(group)

      space_users =
        watching_group_users
        |> Repo.preload(:space_user)
        |> Enum.map(fn group_user -> group_user.space_user end)

      Enum.each(space_users, fn space_user ->
        Posts.subscribe(space_user, [post])
      end)
    end)
  end

  defp record_reply_view(reply, author) do
    Posts.record_reply_views(author, [reply])
  end

  defp mark_as_unread(post, reply, subscribers) do
    Enum.each(subscribers, fn subscriber ->
      # Skip marking unread for the author
      if subscriber.id !== reply.space_user_id do
        Posts.mark_as_unread(subscriber, [post])
      end
    end)
  end

  defp record_notifications(reply, subscribers) do
    Enum.each(subscribers, fn subscriber ->
      if subscriber.id !== reply.space_user_id do
        Notifications.record_reply_created(subscriber, reply)
      end
    end)
  end

  defp send_push_notifications(post, reply, author, opts) do
    presence = Keyword.get(opts, :presence)
    web_push = Keyword.get(opts, :web_push)

    payload = build_push_payload(reply, author)

    ("posts:" <> post.id)
    |> presence.list()
    |> Enum.filter(fn {_, value} -> Enum.any?(value.metas, fn meta -> meta.expanded end) end)
    |> Enum.map(fn {key, _} -> key end)
    |> Enum.each(fn user_id ->
      if user_id != author.user_id do
        web_push.send_web_push(user_id, payload)
      end
    end)
  end

  defp send_events(post, %{reply: reply}, opts) do
    events = Keyword.get(opts, :events)
    {:ok, space_user_ids} = Posts.get_accessor_ids(post)

    events.reply_created(space_user_ids, reply)
  end

  defp can_access_post?(space_user, post_id) do
    case Posts.get_post(space_user, post_id) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
