package WriteOff::Controller::Art;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller'; }

=head1 NAME

WriteOff::Controller::Art - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

=head2 index :PathPart('art') :Chained('/') CaptureArgs(1)

Grabs an image

=cut

sub index :PathPart('art') :Chained('/') :CaptureArgs(1) {
    my ( $self, $c, $arg ) = @_;
	
	my $id = eval { no warnings; int $arg };
	$c->stash->{image} = $c->model('DB::Image')->find($id) or 
		$c->detach('/default');
	
	if( $arg ne $c->stash->{image}->id_uri ) {
		$c->res->redirect
		( $c->uri_for( $c->action, [ $c->stash->{image}->id_uri ] ) );
	}
}

sub submit :PathPart('submit') :Chained('/event/art') :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->stash->{template} = 'art/submit.tt';
	
	$c->forward('/captcha_get');
	$c->forward('do_submit') if 
		$c->req->method eq 'POST' && $c->stash->{event}->art_subs_allowed;
}

sub do_submit :Private {
	my ( $self, $c ) = @_;

	$c->req->params->{captcha} = $c->forward('/captcha_check');
	
	my $img = $c->req->upload('image');
	if( $img ) {
		$c->req->params->{image}    = 1;
		$c->req->params->{mimetype} = $img->mimetype;
		$c->req->params->{filesize} = $img->size;
	} 
	else {
		delete $c->req->params->{image};
	}
	
	$c->form(
		title => [ 
			'NOT_BLANK',
			[ 'LENGTH', 1, $c->config->{len}{max}{title} ], 
			'TRIM_COLLAPSE', 
			[ 'DBIC_UNIQUE', $c->model('DB::Image'), 'title' ],
		],
		artist => [ 
			[ 'LENGTH', 1, $c->config->{len}{max}{user} ],
			'TRIM_COLLAPSE',
		],
		website      => [ 'HTTP_URL' ],
		image        => [ 'NOT_BLANK' ],
		mimetype     => [ [ 'IN_ARRAY', @{ $c->config->{biz}{img}{types} } ] ],
		captcha      => [ $c->user ? () : [ 'EQUAL_TO', 1 ] ],
		filesize     => [ [ 'LESS_THAN', $c->config->{biz}{img}{size} ] ],
	);
	
	if(!$c->form->has_error) {
		
		my %row = (
			event_id => $c->stash->{event}->id,
			user_id  => $c->user ? $c->user->get('id') : undef,
			ip       => $c->req->address,
			title    => $c->form->valid('title'),
			artist   => $c->form->valid('artist') || 'Anonymous',
			website  => $c->form->valid('website') || undef,
			filesize => $img->size,
			mimetype => $img->mimetype,
			seed     => rand,
		);
		
		my $magick = Image::Magick->new;
		$magick->Read     ( $img->tempname );
		$row{contents} =  ( $magick->ImageToBlob )[0];
		
		$magick->Resize( geometry => '250x250' );
		$row{thumb} =  ( $magick->ImageToBlob  )[0];
		
		$c->model('DB::Image')->create(\%row);
		
		$c->flash->{status_msg} = 'Submission successful';
		$c->res->redirect( $c->req->referer || $c->uri_for('/') );
	}
}

sub view :PathPart('') :Chained('index') :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->res->content_type( $c->stash->{image}->mimetype );
	$c->res->body( $c->req->params->{thumb} ? $c->stash->{image}->thumb : 
		$c->stash->{image}->contents );
}

sub delete :PathPart('delete') :Chained('index') :Args(0) {
	my ( $self, $c ) = @_;
	
	$c->detach('/forbidden', ['You cannot delete this item.']) unless
		$c->stash->{image}->is_manipulable_by( $c->user );
		
	$c->stash->{template} = 'delete.tt';
	
	$c->forward('do_delete') if $c->req->method eq 'POST';
}

sub do_delete :Private {
	my ( $self, $c ) = @_;
	
	$c->form(
		title     => [ 'NOT_BLANK', [ 'IN_ARRAY', $c->stash->{image}->title ] ],
		sessionid => [ 'NOT_BLANK', [ 'IN_ARRAY', $c->sessionid ] ],
	);
	
	if( !$c->form->has_error ) {
		$c->stash->{image}->delete;
		$c->flash->{status_msg} = 'Deletion successful';
		$c->res->redirect( $c->uri_for('/user/me') );	
	}
	else {
		$c->stash->{error_msg} = 'Title is incorrect';
	}
	
}


=head1 AUTHOR

Cameron Thornton E<lt>cthor@cpan.orgE<gt>

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
