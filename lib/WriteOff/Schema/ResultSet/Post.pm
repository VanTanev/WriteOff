package WriteOff::Schema::ResultSet::Post;

use strict;
use warnings;
use base 'WriteOff::Schema::ResultSet';

sub artists_hash {
	my $self = shift;

	# Undo the paging, we want to get all artists in the thread
	my %artists =
		map { $_->id => $_ } $self->fresh
			->search({ event_id => $self->get_column('event_id')->first })
			->related_resultset('artist')
			->all;

	return \%artists;
}

sub fresh {
	shift->result_source->schema->resultset('Post');
}

sub num_for {
	my ($self, $post) = @_;

	$self->search({
		id => { '<=' => $post->id },
		created => { '<=' => $post->created },
	})->count;
}

sub thread {
	my ($self, $page, $rows) = @_;

	$page //= 1;
	$rows //= 100;

	$self->search_rs({}, {
		page => $page,
		rows => $rows,
		order_by => [
			{ -asc => 'me.created' },
			{ -asc => 'me.id' },
		],
	});
}

sub thread_prefetch {
	my $self = shift;

	$self->search({}, {
		prefetch => [
			'entry',
			{ reply_children => 'child' }
		]
	});
}

sub thread_prefetch_rs {
	scalar shift->thread_prefetch;
}

sub vote_map {
	my ($self, $user) = @_;

	return {} if !$user;

	my %map = map { $_->id => 1 }
		$self->fresh->search(
			{ 'votes.user_id' => $user->id },
			{ join => 'votes' })->all;

	\%map;
}

1;
