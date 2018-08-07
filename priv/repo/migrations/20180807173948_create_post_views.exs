defmodule Level.Repo.Migrations.CreatePostViews do
  use Ecto.Migration

  def change do
    create table(:post_views, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :space_id, references(:spaces, on_delete: :nothing, type: :binary_id), null: false
      add :post_id, references(:posts, on_delete: :nothing, type: :binary_id), null: false

      add :space_user_id, references(:space_users, on_delete: :nothing, type: :binary_id),
        null: false

      add :last_viewed_reply_id, references(:replies, on_delete: :nothing, type: :binary_id)
      add :occurred_at, :naive_datetime, null: false
    end
  end
end
