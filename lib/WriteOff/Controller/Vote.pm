package WriteOff::Controller::Vote;
use Moose;
use namespace::autoclean;
use Scalar::Util qw/looks_like_number/;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

WriteOff::Controller::Vote - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

sub cast :Private {
	my ($self, $c) = @_;

	if ($c->stash->{round} && $c->user) {
		my $record = $c->stash->{event}->vote_records->search({
			user_id => $c->user->id,
			round   => $c->stash->{round},
			type    => $c->stash->{type},
		})->first;

		if (!$record) {
			$record = $c->stash->{event}->create_related('vote_records', {
				abstains => 3,
				user_id => $c->user->id,
				round => $c->stash->{round},
				type  => $c->stash->{type},
			});

			if ($c->stash->{type} eq 'fic') {
				my $mins = $c->stash->{countdown}->delta_ms($c->stash->{now})->in_units('minutes');
				$c->log->info($mins);
				my $w = $mins / 1440 * $c->config->{work}{threshold} * $c->config->{work}{voter};

				while ($w > 0 && (my $story = $c->stash->{candidates}->next)) {
					next if $story->user_id == $c->user->id;
					$w -= $story->wordcount / $c->config->{work}{rate} + $c->config->{work}{offset};
					$story->create_related('votes', { record_id => $record->id });
				}
			}
		}

		$c->stash->{record} = $record;
		$c->stash->{ordered} = $record->votes->search(
			{ value => { '!=' => undef }},
			{ order_by => { -desc => 'value' }}
		);
		$c->stash->{unordered} = $record->votes->search({ value => undef, abstained => 0 });
		$c->stash->{abstained} = $record->votes->search({ abstained => 1 });
	}

	push $c->stash->{title}, $c->stash->{label} || 'Vote';
	$c->stash->{template} = 'vote/cast.tt';

	$c->forward('do_cast') if $c->req->method eq 'POST';
}

sub do_cast :Private {
	my ($self, $c) = @_;

	my $record = $c->stash->{record};
	return unless $record;

	my $action = $c->req->params->{action} // 'reorder';
	if ($action eq 'abstain') {
		my $id = $c->req->params->{vote};
		return unless looks_like_number $id;

		my $vote = $record->votes->find($id);
		$c->detach('/error', [ 'Vote not found' ]) unless $vote;

		if (!$vote->abstained) {
			$c->detach('/error', [ 'You have no more abstains' ])
				if defined $record->abstains && $record->abstains <= 0;

			$vote->update({ abstained => 1, value => undef });
			if (defined $record->abstains) {
				$record->update({ abstains => $record->abstains - 1 });
			}

			$c->res->body($record->abstains // -1);
		}
		else {
			$vote->update({ abstained => 0 });
			if (defined $record->abstains) {
				$record->update({ abstains => $record->abstains + 1 });
			}
			$c->res->body($record->abstains // -1);
		}
	}
	elsif ($action eq 'append') {
		$c->detach('/error', [ 'You have candidates remaining' ]) if $c->stash->{unordered}->count;

		while (my $item = $c->stash->{candidates}->next) {
			next if $item->user_id == $c->user->id;
			next if $item->votes->search({ record_id => $record->id })->count;

			$c->stash->{vote} = $item->create_related('votes', { record_id => $record->id });
			$c->stash->{template} = 'vote/ballot-item.tt';
			last;
		}
	}
	elsif ($action eq 'reorder') {
		my @ids = $c->req->param("order[]");
		my $votes = $record->votes;

		my %okay = map { $_->id => 1 } $votes->search({ abstained => 0 });
		for my $id (@ids) {
			$c->detach('/error', [ 'Bad input' ]) unless $okay{$id};
		}

		my $score = @ids;
		for my $id (@ids) {
			$votes->find($id)->update({ value => $score });
			$score--;
		}
	}
}

sub fic :PathPart('vote') :Chained('/event/fic') :Args(0) {
	my ($self, $c) = @_;

	my $e = $c->stash->{event};

	$c->stash->{type} = 'fic';
	$c->stash->{view} = $c->controller('Fic')->action_for('view');

	if ($e->prelim_votes_allowed) {
		$c->stash->{round} = 'prelim';
		$c->stash->{label} = 'Prelims';
		$c->stash->{countdown} = $e->public;
		$c->stash->{candidates} = $e->storys->eligible->sample;
	} elsif ($e->public_votes_allowed) {
		$c->stash->{round} = 'public';
		$c->stash->{label} = $e->public_label;
		$c->stash->{countdown} = $e->private || $e->end;
		$c->stash->{candidates} = $e->storys->candidates->sample;
	} elsif ($e->private_votes_allowed) {
		$c->stash->{round} = 'private';
		$c->stash->{label} = 'Finals';
		$c->stash->{countdown} = $e->end;
		$c->stash->{candidates} = $e->storys->finalists->sample;
	} elsif (!$e->ended) {
		$c->stash->{countdown} = $e->prelim || $e->public || $e->private;
	}

	$c->forward('cast');
}

sub prelim :PathPart('vote/prelim') :Chained('/event/fic') :Args(0) {
	my ( $self, $c ) = @_;
	my $e = $c->stash->{event};

	$c->detach('/error', [ $c->strings->{noPrelim} ]) unless $e->prelim;

	if ($c->user) {
		$c->stash->{records} = $e->vote_records->search({
			round   => 'prelim',
			type    => 'fic',
			user_id => $c->user->id,
		});

		$c->stash->{requestable} = !$c->stash->{records}->unfilled->count;

		if ($c->req->method eq 'POST' && $e->prelim_votes_allowed) {
			if ($c->stash->{requestable}) {
				my $err = $e->new_prelim_record_for(
					$c->user, $c->config->{work},
				);

				if ($err) {
					$c->stash->{error_msg} = $err;
				}
				else {
					$c->res->redirect($c->req->uri);
				};
			}
			else {
				$c->stash->{error_msg} = "You have empty records to fill in";
			}
		}
	}

	$c->stash(
		votes_received => $e->vote_records->prelim->filled->count,
	);

	push $c->stash->{title}, 'Vote', 'Prelim';
	$c->stash->{template} = 'vote/rank.tt';
}

sub private :PathPart('vote/private') :Chained('/event/fic') :Args(0) {
	my ( $self, $c ) = @_;
	my $e = $c->stash->{event};

	$c->detach('/error', [ $c->strings->{noPrivate} ]) unless $e->private;

	$c->stash->{record} = $e->vote_records->search({
		round => 'private',
		type => 'fic',
		user_id => $c->user->id
	});

	$c->stash->{finalists} = $e->storys->search(
		{ finalist => 1 },
		{ order_by => 'title' },
	);

	$c->stash(
		judge => $e->judges->find($c->user_id),
		votes_received => $e->vote_records->private->filled->count,
	);

	$c->stash->{records} = $e->vote_records->unfilled->search({
		round    => 'private',
		type     => 'fic',
		user_id  => $c->stash->{judge}->id,
	})->unfilled if $c->stash->{judge};

	push $c->stash->{title}, 'Vote', 'Private';
	$c->stash->{template} = 'vote/rank.tt';
}

=head1 AUTHOR

Cameron Thornton E<lt>cthor@cpan.orgE<gt>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
