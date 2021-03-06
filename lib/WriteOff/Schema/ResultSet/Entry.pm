package WriteOff::Schema::ResultSet::Entry;

use strict;
use warnings;
use base 'WriteOff::Schema::ResultSet';
use WriteOff::Award qw/:all/;
require List::Util;

sub artists_hash {
	my $self = shift;
	my %artists = map { $_->id => $_ } $self->related_resultset('artist')->all;
	\%artists;
}

sub eligible {
	shift->search({ disqualified => 0 });
}

sub decay {
	my ($self, $genre, $format) = @_;

	my $scores = $self->search(
		{ score => { '!=' => undef } },
		{ join => 'event' });

	my $gScores = $scores->search({ genre_id => $genre->id });
	$gScores->update({ score_genre => \q{score_genre * 0.9} });

	my $fScores = $gScores->search({ format_id => $format->id });
	$fScores->update({ score_format => \q{score_format * 0.9} });
}

sub difficulty {
	my $self = shift;

	List::Util::sum(map { sqrt $_->difficulty } $self->all) / $self->count;
}

sub disqualified {
	shift->search({ disqualified => 1 });
}

sub gallery {
	my $self = shift;

	my $num_rs = $self->search(
		{
			event_id => { '=' => { -ident => 'me.event_id' }},
			seed => { '>' => { -ident => "me.seed" } },
		},
		{
			'select' => [ \'COUNT(*) + 1' ],
			'alias' => 'subq',
		}
	);

	$self->search({}, {
		'+select' => [ $num_rs->as_query ],
		'+as' => [ 'num' ],
		join => 'round',
		order_by => [
			{ -asc => 'disqualified' },
			{ -desc => 'round.end' },
			{ -desc => 'seed' },
		],
	});
}

sub listing {
	shift->search({
		artist_public => 1,
		tallied => 1,
	}, {
		join => 'event',
		prefetch => 'event',
		order_by => [
			{ -desc => 'event.created' },
			{ -asc => 'title' },
		],
	});
}

sub mode {
	my ($self, $mode) = @_;

	$self->search({
		$mode eq 'art' ? (image_id => { '!=' => undef }) :
		$mode eq 'fic' ? (story_id => { '!=' => undef }) :
		()
	});
}

sub public {
	shift->search({ artist_public => 1 });
}

sub public_rs {
	scalar shift->public;
}

sub rank_order {
	return shift->order_by({ -asc => [qw/rank title/] });
}

sub recalc_rank {
	my $self = shift;

	my @entrys = $self->all;
	my %ratings;
	for my $entry (@entrys) {
		$ratings{$entry->id} = [
			map { $_->value } $entry->ratings->search({}, {
				join => 'round',
				order_by => { -desc => 'round.end' },
			})
		];
	}

	my $cmp = sub {
		my ($l, $r) = @_;
		my @l = @{ $ratings{$l->id} };
		my @r = @{ $ratings{$r->id} };

		if (@l > @r) {
			return 1;
		}
		elsif (@r > @l) {
			return -1;
		}
		for my $i (0..$#l) {
			if ($l[$i] > $r[$i]) {
				return 1;
			}
			elsif ($r[$i] > $l[$i]) {
				return -1;
			}
		}
		return 0;
	};

	@entrys = sort $cmp @entrys;

	my @ranks = [ shift @entrys ];
	for my $entry (@entrys) {
		if ($cmp->($entry, $ranks[-1][0]) == 0) {
			push @{ $ranks[-1] }, $entry;
		}
		else {
			push @ranks, [ $entry ];
		}
	}

	my $i = 0;
	for my $rank (@ranks) {
		for my $entry (@$rank) {
			$entry->update({
				rank     => $i,
				rank_low => $i + $#$rank,
			});
		}
		$i += @$rank;
	}
}

sub sample {
	shift->search({}, {
		'+select', => [ \'COUNT(votes.value)' ],
		'+as' => [ 'priority' ],
		join => 'votes',
		group_by => 'me.id',
		order_by => [
			{ -asc => \'count(votes.value)' },
			{ -desc => \'RANDOM()' },
		],
	});
}

sub seed_order {
	return shift->order_by({ -desc => 'seed' });
}

sub tally {
	my ($self, $rounds) = @_;

	if ($self->count) {
		$self->_tally_awards($rounds);
		$self->_tally_scores;
	}
}

sub _tally_awards {
	my ($self, $rounds) = @_;

	my %artists;
	my %last;
	my @medals = ( GOLD, SILVER, BRONZE );

	my %mxerr = map { $_->id => $_->ratings->get_column('error')->max } $rounds->all;
	my $n = $self->count - 1;

	for my $entry ($self->rank_order->all) {
		my $aid = $entry->artist_id;

		my @awards;
		for my $rating ($entry->ratings) {
			if ($mxerr{$rating->round_id} == $rating->error) {
				push @awards, CONFETTI();
			}
		}

		if (!exists $artists{$aid}) {
			if (%last && $last{rank} == $entry->rank) {
				push @awards, $last{medal};
				shift @medals;
			} elsif (@medals) {
				push @awards, shift @medals;
				%last = (rank => $entry->rank, medal => $awards[-1]);
			} else {
				undef %last;
			}

			$artists{$aid} = [ [ $entry, RIBBON ] ];
		}

		for my $award (@awards) {
			push @{ $artists{$aid} }, [ $entry, $award ];
		}
	}

	my $awards_rs = $self->result_source->schema->resultset('Award');
	while (my ($aid, $awards) = each %artists) {
		# Shift ribbon off
		if (@$awards != 1) {
			shift @$awards;
		}

		for (@$awards) {
			$awards_rs->create({
				entry_id => $_->[0]->id,
				award_id => $_->[1]->id,
			});
		}
	}
}

sub _tally_scores {
	my $self = shift;

	# Multiply by 10 because whole numbers are nicer to display than
	# numbers with one decimal place
	my $D = $self->difficulty * 10;

	my $n = $self->count - 1;
	my %artists;
	for my $entry ($self->rank_order->all) {
		my $aid = $entry->artist_id;

		my $pos = ($entry->rank + $entry->rank_low) / 2;
		my $pct = ($n-$pos)/($n+1);
		my $score = $D * $pct ** 1.6;

		if (exists $artists{$aid}) {
			# Additional entries have a small deduction
			$score -= $D * 0.2;
		}
		else {
			$artists{$aid} = 1;
		}

		$entry->update({
			score => $score,
			score_format => $score,
			score_genre => $score,
		});
	}
}

1;
