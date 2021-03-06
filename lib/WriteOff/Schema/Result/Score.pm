package WriteOff::Schema::Result::Score;

use base qw/DBIx::Class::Core/;
use WriteOff::Award;
use WriteOff::Util ();

__PACKAGE__->table_class('DBIx::Class::ResultSource::View');
__PACKAGE__->table('scores');

__PACKAGE__->add_columns(
	"id",
	{ data_type => "integer" },
	"name",
	{ data_type => "text" },
	"score",
	{ data_type => "real" },
	"format_id",
	{ data_type => "integer", is_foreign_key => 1 },
	"genre_id",
	{ data_type => "integer", is_foreign_key => 1 },
);

__PACKAGE__->result_source_instance->view_definition(q{
	SELECT
	  artists.id AS id,
	  artists.name AS name,
	  SUM(entrys.score_genre) AS score,
	  events.genre_id AS genre_id,
	  NULL AS format_id
	FROM
	  artists
	CROSS JOIN
	  entrys ON artists.id=entrys.artist_id
	CROSS JOIN
	  events ON entrys.event_id=events.id AND events.tallied=1
	WHERE
	  disqualified=0 AND artist_public=1
	GROUP BY
	  artists.id, genre_id

	UNION

	SELECT
	  artists.id AS id,
	  artists.name AS name,
	  SUM(entrys.score_format) AS score,
	  events.genre_id AS genre_id,
	  events.format_id AS format_id
	FROM
	  artists
	CROSS JOIN
	  entrys ON artists.id=entrys.artist_id
	CROSS JOIN
	  events ON entrys.event_id=events.id AND events.tallied=1
	WHERE
	  disqualified=0 AND artist_public=1
	GROUP BY
	  artists.id, genre_id, format_id

	ORDER BY score DESC
});

__PACKAGE__->result_source_instance->deploy_depends_on([
	"WriteOff::Schema::Result::Artist",
	"WriteOff::Schema::Result::Entry",
	"WriteOff::Schema::Result::Event",
]);

sub id_uri {
	my $self = shift;
	WriteOff::Util::simple_uri $self->id, $self->name;
}

sub tally_awards {
	my ($self, $awards, $cols) = @_;

	my %bin = map { $_->award_id => 0 } @$cols;
	$bin{$_->award_id}++ for $awards->search(
		{ "entry.artist_id" => $self->id },
		{ join => 'entry' },
	)->all;

	my @tally;
	for my $award (@$cols) {
		push @tally, {
			award => $award,
			count => $bin{$award->award_id},
		};
	}

	return \@tally;
}

1;
