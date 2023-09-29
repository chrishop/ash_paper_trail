defmodule AshPaperTrailTest do
  use ExUnit.Case

  alias AshPaperTrail.Test.{Posts, Articles, Accounts}

  @valid_attrs %{
    subject: "subject",
    body: "body",
    secret: "password",
    author: %{first_name: "John", last_name: "Doe"},
    tags: [%{tag: "ash"}, %{tag: "phoenix"}]
  }
  describe "operations over resource api (without a registry)" do
    test "creates work as normal" do
      assert %{subject: "subject", body: "body"} =
               Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert [%{subject: "subject", body: "body"}] = Posts.Post.read!(tenant: "acme")
    end

    test "updates work as normal" do
      assert %{subject: "subject", body: "body", tenant: "acme"} =
               post = Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert %{subject: "new subject", body: "new body"} =
               Posts.Post.update!(post, %{subject: "new subject", body: "new body"})

      assert [%{subject: "new subject", body: "new body"}] =
               Posts.Post.read!(tenant: "acme")
    end

    test "destroys work as normal" do
      assert %{subject: "subject", body: "body", tenant: "acme"} =
               post = Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert :ok = Posts.Post.destroy!(post)

      assert [] = Posts.Post.read!(tenant: "acme")
    end

    test "existing allow mfa is called" do
      Posts.Post.create!(@valid_attrs, tenant: "acme")
      assert_received :existing_allow_mfa_called
    end
  end

  describe "version resource" do
    test "a new version is created on create" do
      assert %{subject: "subject", body: "body", id: post_id} =
               Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert [
               %{
                 subject: "subject",
                 body: "body",
                 changes: %{
                   subject: "subject",
                   body: "body",
                   author: %{autogenerated_id: _author_id, first_name: "John", last_name: "Doe"},
                   tags: [
                     %{tag: "ash", autogenerated_id: _tag_id1},
                     %{tag: "phoenix", autogenerated_id: _tag_id2}
                   ]
                 },
                 version_action_type: :create,
                 version_action_name: :create,
                 version_source_id: ^post_id
               }
             ] =
               Articles.Api.read!(Posts.Post.Version, tenant: "acme")
    end

    test "a new version is created on update" do
      assert %{subject: "subject", body: "body", id: post_id} =
               post = Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert %{subject: "new subject", body: "new body"} =
               Posts.Post.update!(post, %{subject: "new subject", body: "new body"},
                 tenant: "acme"
               )

      assert [
               %{
                 subject: "subject",
                 body: "body",
                 version_action_type: :create,
                 version_source_id: ^post_id
               },
               %{
                 subject: "new subject",
                 body: "new body",
                 version_action_type: :update,
                 version_source_id: ^post_id
               }
             ] =
               Posts.Api.read!(Posts.Post.Version, tenant: "acme")
               |> Enum.sort_by(& &1.version_inserted_at)
    end

    test "the action name is stored" do
      assert AshPaperTrail.Resource.Info.store_action_name?(Posts.Post) == true

      post = Posts.Post.create!(@valid_attrs, tenant: "acme")
      Posts.Post.publish!(post, %{}, tenant: "acme")

      [publish_version] =
        Posts.Api.read!(Posts.Post.Version, tenant: "acme")
        |> Enum.filter(&(&1.version_action_type == :update))

      assert %{version_action_type: :update, version_action_name: :publish} = publish_version
    end

    test "the new version only includes changes in :changes_only mode" do
      assert AshPaperTrail.Resource.Info.change_tracking_mode(Posts.Post) == :changes_only

      post = Posts.Post.create!(@valid_attrs, tenant: "acme")
      Posts.Post.update!(post, %{subject: "new subject"}, tenant: "acme")

      [updated_version] =
        Posts.Api.read!(Posts.Post.Version, tenant: "acme")
        |> Enum.filter(&(&1.version_action_type == :update))

      assert [:subject] = Map.keys(updated_version.changes)
    end

    test "the new version only includes changes in :snapshot mode" do
      assert AshPaperTrail.Resource.Info.change_tracking_mode(Articles.Article) == :snapshot

      article = Articles.Article.create!("subject", "body")
      Articles.Article.update!(article, %{subject: "new subject"})

      [updated_version] =
        Articles.Api.read!(Articles.Article.Version)
        |> Enum.filter(&(&1.version_action_type == :update))

      assert [:body, :subject] =
               Map.keys(updated_version.changes) |> Enum.sort()
    end

    test "a new version is created on destroy" do
      assert %{subject: "subject", body: "body", id: post_id} =
               post = Posts.Post.create!(@valid_attrs, tenant: "acme")

      assert :ok = Posts.Post.destroy!(post, tenant: "acme")

      assert [
               %{
                 subject: "subject",
                 body: "body",
                 version_action_type: :create,
                 version_source_id: ^post_id
               },
               %{
                 subject: "subject",
                 body: "body",
                 version_action_type: :destroy,
                 version_source_id: ^post_id
               }
             ] =
               Posts.Api.read!(Posts.Post.Version, tenant: "acme")
               |> Enum.sort_by(& &1.version_inserted_at)
    end
  end

  describe "belongs_to_actor option" do
    test "creates a relationship on the version" do
      assert length(AshPaperTrail.Resource.Info.belongs_to_actor(Posts.Post)) > 1

      relationships_on_version = Ash.Resource.Info.relationships(Posts.Post.Version)

      Enum.each(AshPaperTrail.Resource.Info.belongs_to_actor(Posts.Post), fn belongs_to_actor ->
        name = belongs_to_actor.name
        destination = belongs_to_actor.destination
        attribute_type = belongs_to_actor.attribute_type
        api = belongs_to_actor.api
        allow_nil? = belongs_to_actor.allow_nil?

        assert %Ash.Resource.Relationships.BelongsTo{
                 name: ^name,
                 destination: ^destination,
                 attribute_type: ^attribute_type,
                 source: AshPaperTrail.Test.Posts.Post.Version,
                 api: ^api,
                 allow_nil?: ^allow_nil?,
                 attribute_writable?: true
               } = Enum.find(relationships_on_version, &(&1.name == name))
      end)
    end

    test "sets a relationship on the versions" do
      user = Accounts.User.create!(%{name: "bob"})
      user_id = user.id

      news_feed = Accounts.NewsFeed.create!(%{organization: "ap"})
      news_feed_id = news_feed.id

      post = Posts.Post.create!(@valid_attrs, tenant: "acme", actor: news_feed)
      post = Posts.Post.publish!(post, tenant: "acme", actor: user)

      post =
        Posts.Post.update!(post, %{subject: "new subject"}, tenant: "acme", actor: "a string")

      post_id = post.id

      assert(
        [
          %{
            subject: "subject",
            body: "body",
            version_action_type: :create,
            version_source_id: ^post_id,
            user_id: nil,
            news_feed_id: ^news_feed_id
          },
          %{
            subject: "subject",
            body: "body",
            version_action_type: :update,
            version_source_id: ^post_id,
            user_id: ^user_id,
            news_feed_id: nil
          },
          %{
            subject: "new subject",
            body: "body",
            version_action_type: :update,
            version_source_id: ^post_id,
            user_id: nil,
            news_feed_id: nil
          }
        ] =
          Posts.Api.read!(Posts.Post.Version, tenant: "acme")
          |> Enum.sort_by(& &1.version_inserted_at)
      )
    end
  end

  describe "operations over resource with an Api Registry (Not Recommended)" do
    test "creates work as normal" do
      assert %{subject: "subject", body: "body"} = Articles.Article.create!("subject", "body")
      assert [%{subject: "subject", body: "body"}] = Articles.Article.read!()
    end

    test "updates work as normal" do
      assert %{subject: "subject", body: "body"} =
               post = Articles.Article.create!("subject", "body")

      assert %{subject: "new subject", body: "new body"} =
               Articles.Article.update!(post, %{subject: "new subject", body: "new body"})

      assert [%{subject: "new subject", body: "new body"}] = Articles.Article.read!()
    end

    test "destroys work as normal" do
      assert %{subject: "subject", body: "body"} =
               post = Articles.Article.create!("subject", "body")

      assert :ok = Articles.Article.destroy!(post)

      assert [] = Articles.Article.read!()
    end
  end
end
